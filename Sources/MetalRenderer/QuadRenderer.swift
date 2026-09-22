import Foundation
import Metal
import simd
import os

/// One textured quad to draw.
public struct QuadDraw {
    /// Model matrix: placement, rotation and scale in scene space.
    public var transform: simd_float4x4
    /// Sub-rectangle of the texture to sample, as (u0, v0, u1, v1). Sprite sheets and atlased
    /// textures address a frame through this rather than by slicing the texture.
    public var uvRect: SIMD4<Float>
    /// Multiplied into the sampled colour. Alpha here is the layer's opacity.
    public var tint: SIMD4<Float>
    public var texture: (any MTLTexture)?
    public var blend: BlendMode

    public init(
        transform: simd_float4x4,
        uvRect: SIMD4<Float> = SIMD4(0, 0, 1, 1),
        tint: SIMD4<Float> = SIMD4(1, 1, 1, 1),
        texture: (any MTLTexture)? = nil,
        blend: BlendMode = .premultipliedAlpha
    ) {
        self.transform = transform
        self.uvRect = uvRect
        self.tint = tint
        self.texture = texture
        self.blend = blend
    }
}

/// One particle as the GPU draws it: where, how big, turned how far, which part of the
/// texture and in what colour. 48 bytes, written straight from the simulation — a particle
/// emitter can be tens of thousands of these a frame, and building a `QuadDraw` apiece, each
/// with its own matrix and a retained texture reference, cost more than simulating them.
public struct ParticleInstance {
    /// x, y, size, rotation (radians).
    public var placement: SIMD4<Float>
    public var uvRect: SIMD4<Float>
    public var tint: SIMD4<Float>

    public init(placement: SIMD4<Float>, uvRect: SIMD4<Float>, tint: SIMD4<Float>) {
        self.placement = placement
        self.uvRect = uvRect
        self.tint = tint
    }
}

/// Draws textured quads. The bulk of a 2D scene is this and nothing else.
///
/// Threading: render-queue only, like everything else in this module.
public final class QuadRenderer {
    private struct Uniforms {
        var mvp: simd_float4x4
        var uvRect: SIMD4<Float>
        var tint: SIMD4<Float>
    }

    private struct PipelineKey: Hashable {
        enum Kind: Hashable { case single, instanced, particles }
        let blend: BlendMode
        let pixelFormat: MTLPixelFormat
        let kind: Kind
    }

    /// Consecutive draws sharing a texture and blend mode are drawn as one instanced draw.
    /// A particle emitter is thousands of them, and one draw call apiece was the largest cost
    /// on the render path in a real library: 20,000 particles meant 20,000 calls a frame, each
    /// paying the driver to re-validate the same state.
    private static let minimumBatch = 4

    /// Per-instance storage for batched draws. Frame command buffers do not retain their
    /// resources, so a buffer written this frame is kept until the GPU has finished with it,
    /// then handed back for reuse.
    private let instanceBuffers = InstanceBufferPool()

    private let device: any MTLDevice
    private let library: any MTLLibrary
    private var pipelines: [PipelineKey: any MTLRenderPipelineState] = [:]
    private let samplerClamp: any MTLSamplerState
    private let samplerRepeat: any MTLSamplerState
    private let log = Logger(subsystem: "app.diorama", category: "quad")

    /// Tracks whether a fallback texture had to be substituted, so the caller can report it.
    public private(set) var missingTextureDraws = 0

    private let fallbackTexture: any MTLTexture

    public init(device: any MTLDevice) throws {
        self.device = device

        // Compiled at runtime from source. Works inside the App Store sandbox — unlike invoking
        // `xcrun metal`, which does not exist there. Should migrate to a precompiled .metallib
        // resource once the build has somewhere to put one.
        library = try device.makeLibrary(source: Self.shaderSource, options: nil)

        let clamp = MTLSamplerDescriptor()
        clamp.minFilter = .linear
        clamp.magFilter = .linear
        clamp.mipFilter = .linear
        clamp.sAddressMode = .clampToEdge
        clamp.tAddressMode = .clampToEdge
        guard let clampState = device.makeSamplerState(descriptor: clamp) else {
            throw RendererError.samplerCreationFailed
        }
        samplerClamp = clampState

        let repeating = MTLSamplerDescriptor()
        repeating.minFilter = .linear
        repeating.magFilter = .linear
        repeating.mipFilter = .linear
        repeating.sAddressMode = .repeat
        repeating.tAddressMode = .repeat
        guard let repeatState = device.makeSamplerState(descriptor: repeating) else {
            throw RendererError.samplerCreationFailed
        }
        samplerRepeat = repeatState

        // A 1x1 white texture stands in for a layer whose texture failed to load, so one bad
        // asset produces a flat-tinted quad instead of a black hole or a dropped draw.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let fallback = device.makeTexture(descriptor: descriptor) else {
            throw RendererError.textureCreationFailed
        }
        var white: UInt32 = 0xFFFF_FFFF
        fallback.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: &white, bytesPerRow: 4
        )
        fallback.label = "quad-fallback-white"
        fallbackTexture = fallback
    }

    public func encode(
        _ draws: [QuadDraw],
        into encoder: any MTLRenderCommandEncoder,
        projection: simd_float4x4,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        wrapsUVs: Bool = false
    ) {
        guard !draws.isEmpty else { return }
        encoder.setFragmentSamplerState(wrapsUVs ? samplerRepeat : samplerClamp, index: 0)

        var lastPipeline: PipelineKey?
        var index = draws.startIndex
        while index < draws.endIndex {
            let draw = draws[index]

            // How many draws from here share this one's texture and blend.
            var end = index + 1
            while end < draws.endIndex, draws[end].blend == draw.blend,
                  draws[end].texture === draw.texture {
                end += 1
            }

            if end - index >= Self.minimumBatch,
               encodeBatch(draws[index ..< end], into: encoder, projection: projection,
                           pixelFormat: pixelFormat, lastPipeline: &lastPipeline) {
                index = end
                continue
            }

            let key = PipelineKey(blend: draw.blend, pixelFormat: pixelFormat, kind: .single)
            if lastPipeline != key {
                guard let pipeline = pipeline(for: key) else {
                    index += 1
                    continue
                }
                encoder.setRenderPipelineState(pipeline)
                lastPipeline = key
            }

            var uniforms = Uniforms(
                mvp: projection * draw.transform,
                uvRect: draw.uvRect,
                tint: draw.tint
            )
            // setVertexBytes rather than a buffer: these are well under the 4KB threshold where
            // Metal's fast path applies, and it avoids managing a ring buffer of tiny uniforms.
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

            if let texture = draw.texture {
                encoder.setFragmentTexture(texture, index: 0)
            } else {
                encoder.setFragmentTexture(fallbackTexture, index: 0)
                missingTextureDraws += 1
            }

            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            index += 1
        }
    }

    /// Draws a run of quads that share a texture and blend mode in one call.
    ///
    /// - Returns: false when no instance storage could be had, so the caller draws them one
    ///   at a time instead.
    private func encodeBatch(
        _ run: ArraySlice<QuadDraw>,
        into encoder: any MTLRenderCommandEncoder,
        projection: simd_float4x4,
        pixelFormat: MTLPixelFormat,
        lastPipeline: inout PipelineKey?
    ) -> Bool {
        guard let first = run.first else { return true }
        let key = PipelineKey(blend: first.blend, pixelFormat: pixelFormat, kind: .instanced)
        guard let pipeline = pipeline(for: key),
              let slot = instanceBuffers.allocate(
                  bytes: run.count * MemoryLayout<Uniforms>.stride, device: device
              )
        else { return false }

        let instances = (slot.buffer.contents() + slot.offset)
            .bindMemory(to: Uniforms.self, capacity: run.count)
        for (offset, draw) in run.enumerated() {
            instances[offset] = Uniforms(
                mvp: projection * draw.transform, uvRect: draw.uvRect, tint: draw.tint
            )
        }

        if lastPipeline != key {
            encoder.setRenderPipelineState(pipeline)
            lastPipeline = key
        }
        encoder.setVertexBuffer(slot.buffer, offset: slot.offset, index: 1)
        if let texture = first.texture {
            encoder.setFragmentTexture(texture, index: 0)
        } else {
            encoder.setFragmentTexture(fallbackTexture, index: 0)
            missingTextureDraws += run.count
        }
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: run.count
        )
        return true
    }

    /// Draws a particle system's instances in one call.
    public func encodeParticles(
        _ instances: UnsafeBufferPointer<ParticleInstance>,
        texture: (any MTLTexture)?,
        blend: BlendMode,
        into encoder: any MTLRenderCommandEncoder,
        projection: simd_float4x4,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) {
        guard let base = instances.baseAddress, !instances.isEmpty else { return }
        let key = PipelineKey(blend: blend, pixelFormat: pixelFormat, kind: .particles)
        let bytes = instances.count * MemoryLayout<ParticleInstance>.stride
        guard let pipeline = pipeline(for: key),
              let slot = instanceBuffers.allocate(bytes: bytes, device: device)
        else { return }
        (slot.buffer.contents() + slot.offset).copyMemory(from: base, byteCount: bytes)

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(samplerClamp, index: 0)
        var projection = projection
        encoder.setVertexBytes(&projection, length: MemoryLayout<simd_float4x4>.stride, index: 0)
        encoder.setVertexBuffer(slot.buffer, offset: slot.offset, index: 1)
        encoder.setFragmentTexture(texture ?? fallbackTexture, index: 0)
        if texture == nil { missingTextureDraws += instances.count }
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count
        )
    }

    /// Hands this frame's instance storage back once `commandBuffer` has run. Call once per
    /// frame, after encoding and before committing.
    public func finishFrame(on commandBuffer: any MTLCommandBuffer) {
        instanceBuffers.finishFrame(on: commandBuffer)
    }

    public func resetCounters() { missingTextureDraws = 0 }

    private func pipeline(for key: PipelineKey) -> (any MTLRenderPipelineState)? {
        if let existing = pipelines[key] { return existing }

        let descriptor = MTLRenderPipelineDescriptor()
        let (vertex, fragment) = switch key.kind {
        case .single: ("quad_vertex", "quad_fragment")
        case .instanced: ("quad_vertex_instanced", "quad_fragment_instanced")
        case .particles: ("particle_vertex", "quad_fragment_instanced")
        }
        descriptor.label = "quad-\(key.blend)-\(key.kind)"
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = key.pixelFormat
        key.blend.apply(to: descriptor.colorAttachments[0])

        do {
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = state
            return state
        } catch {
            log.error("pipeline for \(String(describing: key.blend)) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Vertices are generated from `vertex_id` rather than read from a buffer. A unit quad is
    /// four corners; binding a vertex buffer to carry eight floats costs more than computing
    /// them.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 mvp;
        float4   uvRect;
        float4   tint;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut quad_vertex(uint vid [[vertex_id]],
                                 constant Uniforms &u [[buffer(0)]]) {
        // Triangle-strip order: BL, BR, TL, TR.
        float2 corners[4] = {
            float2(-0.5, -0.5), float2(0.5, -0.5),
            float2(-0.5,  0.5), float2(0.5,  0.5)
        };
        float2 uvs[4] = {
            float2(0.0, 1.0), float2(1.0, 1.0),
            float2(0.0, 0.0), float2(1.0, 0.0)
        };

        VertexOut out;
        out.position = u.mvp * float4(corners[vid], 0.0, 1.0);
        out.uv = mix(u.uvRect.xy, u.uvRect.zw, uvs[vid]);
        return out;
    }

    struct InstancedOut {
        float4 position [[position]];
        float2 uv;
        float4 tint;
    };

    // The same quad, with its uniforms read per instance: one call draws a whole run.
    vertex InstancedOut quad_vertex_instanced(uint vid [[vertex_id]],
                                              uint iid [[instance_id]],
                                              const device Uniforms *instances [[buffer(1)]]) {
        float2 corners[4] = {
            float2(-0.5, -0.5), float2(0.5, -0.5),
            float2(-0.5,  0.5), float2(0.5,  0.5)
        };
        float2 uvs[4] = {
            float2(0.0, 1.0), float2(1.0, 1.0),
            float2(0.0, 0.0), float2(1.0, 0.0)
        };
        Uniforms u = instances[iid];
        InstancedOut out;
        out.position = u.mvp * float4(corners[vid], 0.0, 1.0);
        out.uv = mix(u.uvRect.xy, u.uvRect.zw, uvs[vid]);
        out.tint = u.tint;
        return out;
    }

    struct Particle {
        float4 placement;   // x, y, size, rotation
        float4 uvRect;
        float4 tint;
    };

    // A particle's quad is built here from its placement, so the CPU writes 48 bytes and no
    // matrix, and the rotation's sine and cosine are the GPU's to take.
    vertex InstancedOut particle_vertex(uint vid [[vertex_id]],
                                        uint iid [[instance_id]],
                                        constant float4x4 &projection [[buffer(0)]],
                                        const device Particle *particles [[buffer(1)]]) {
        float2 corners[4] = {
            float2(-0.5, -0.5), float2(0.5, -0.5),
            float2(-0.5,  0.5), float2(0.5,  0.5)
        };
        float2 uvs[4] = {
            float2(0.0, 1.0), float2(1.0, 1.0),
            float2(0.0, 0.0), float2(1.0, 0.0)
        };
        Particle p = particles[iid];
        float c = cos(p.placement.w), s = sin(p.placement.w);
        float2 corner = corners[vid] * p.placement.z;
        float2 turned = float2(c * corner.x - s * corner.y, s * corner.x + c * corner.y);
        InstancedOut out;
        out.position = projection * float4(p.placement.xy + turned, 0.0, 1.0);
        out.uv = mix(p.uvRect.xy, p.uvRect.zw, uvs[vid]);
        out.tint = p.tint;
        return out;
    }

    fragment float4 quad_fragment_instanced(InstancedOut in [[stage_in]],
                                            texture2d<float> tex [[texture(0)]],
                                            sampler samp [[sampler(0)]]) {
        float4 color = tex.sample(samp, in.uv) * in.tint;
        color.rgb *= color.a;
        return color;
    }

    fragment float4 quad_fragment(VertexOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]],
                                  sampler samp [[sampler(0)]]) {
        float4 color = tex.sample(samp, in.uv) * u.tint;

        // Wallpaper Engine textures carry STRAIGHT alpha, but every blend mode here is
        // premultiplied. Converting at sample time is what makes soft-edged content actually
        // look soft: without this, a premultiplied-additive pass adds RGB at full strength
        // regardless of alpha, so an anti-aliased particle sprite renders as a hard square.
        // Doing it in the shader rather than by picking non-premultiplied blend factors keeps
        // one consistent convention across all modes.
        color.rgb *= color.a;
        return color;
    }
    """
}

public enum RendererError: Error, LocalizedError {
    case samplerCreationFailed
    case textureCreationFailed
    case libraryCompilationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .samplerCreationFailed: "Could not create a texture sampler"
        case .textureCreationFailed: "Could not allocate a texture"
        case .libraryCompilationFailed(let detail): "Shader compilation failed: \(detail)"
        }
    }
}

/// Reusable storage for instanced draws, handed back once the GPU is done with it.
///
/// One frame's instances are packed into as few buffers as fit; a buffer goes back to the free
/// list from the completion handler of the command buffer that read it. Completion handlers run
/// on Metal's own thread, hence the lock.
final class InstanceBufferPool: @unchecked Sendable {
    struct Slot {
        let buffer: any MTLBuffer
        let offset: Int
    }

    /// Instance data is read by `instance_id`, so a run's start only needs the struct's own
    /// alignment; 256 is what Metal requires of a buffer offset on every GPU.
    private static let alignment = 256
    private static let minimumBufferSize = 256 * 1024

    private let lock = OSAllocatedUnfairLock<[any MTLBuffer]>(uncheckedState: [])
    private var inUse: [any MTLBuffer] = []
    private var current: (buffer: any MTLBuffer, used: Int)?

    func allocate(bytes: Int, device: any MTLDevice) -> Slot? {
        if let current, current.used + bytes <= current.buffer.length {
            let slot = Slot(buffer: current.buffer, offset: current.used)
            self.current = (current.buffer, Self.aligned(current.used + bytes))
            return slot
        }
        let reused = lock.withLockUnchecked { free -> (any MTLBuffer)? in
            guard let index = free.firstIndex(where: { $0.length >= bytes }) else { return nil }
            return free.remove(at: index)
        }
        guard let buffer = reused ?? device.makeBuffer(
            length: max(Self.minimumBufferSize, Self.aligned(bytes)),
            options: [.storageModeShared, .cpuCacheModeWriteCombined]
        ) else { return nil }
        buffer.label = "quad-instances"
        inUse.append(buffer)
        current = (buffer, Self.aligned(bytes))
        return Slot(buffer: buffer, offset: 0)
    }

    /// The render thread lets go of a frame's buffers here and the completion handler takes
    /// them; nothing touches them in between, which is what makes the hand-off safe.
    private struct Handoff: @unchecked Sendable { let buffers: [any MTLBuffer] }

    func finishFrame(on commandBuffer: any MTLCommandBuffer) {
        let used = Handoff(buffers: inUse)
        inUse = []
        current = nil
        guard !used.buffers.isEmpty else { return }
        commandBuffer.addCompletedHandler { [lock] _ in
            lock.withLockUnchecked { free in
                free.append(contentsOf: used.buffers)
                // Bounded, so one enormous frame does not pin its buffers forever.
                if free.count > 8 { free.removeFirst(free.count - 8) }
            }
        }
    }

    private static func aligned(_ value: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }
}
