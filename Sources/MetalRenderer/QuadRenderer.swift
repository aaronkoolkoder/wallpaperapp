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
        let blend: BlendMode
        let pixelFormat: MTLPixelFormat
    }

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

        var lastBlend: BlendMode?
        for draw in draws {
            if lastBlend != draw.blend {
                guard let pipeline = pipeline(for: draw.blend, pixelFormat: pixelFormat) else {
                    continue
                }
                encoder.setRenderPipelineState(pipeline)
                lastBlend = draw.blend
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
        }
    }

    public func resetCounters() { missingTextureDraws = 0 }

    private func pipeline(
        for blend: BlendMode, pixelFormat: MTLPixelFormat
    ) -> (any MTLRenderPipelineState)? {
        let key = PipelineKey(blend: blend, pixelFormat: pixelFormat)
        if let existing = pipelines[key] { return existing }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "quad-\(blend)"
        descriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "quad_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        blend.apply(to: descriptor.colorAttachments[0])

        do {
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = state
            return state
        } catch {
            log.error("pipeline for \(String(describing: blend)) failed: \(error.localizedDescription, privacy: .public)")
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
