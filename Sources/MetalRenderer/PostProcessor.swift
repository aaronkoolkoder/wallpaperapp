import Foundation
import Metal
import simd
import os

/// A post-process effect this renderer can actually run.
///
/// Wallpaper Engine effects are arbitrary shader chains, and running one faithfully needs its
/// GLSL transpiled to MSL — which is built but not yet wired to a native backend. Until it is,
/// effects are matched by name onto these built-in implementations. That covers the handful of
/// effects that appear in most wallpapers (bloom and blur above all), and anything unmatched is
/// reported to the user rather than silently dropped.
public enum PostEffect: Sendable, Hashable {
    case gaussianBlur(radius: Float)
    case bloom(threshold: Float, intensity: Float)
    case vignette(intensity: Float)
    case chromaticAberration(amount: Float)
    case sharpen(amount: Float)
    case pixelate(size: Float)

    public var debugName: String {
        switch self {
        case .gaussianBlur: "blur"
        case .bloom: "bloom"
        case .vignette: "vignette"
        case .chromaticAberration: "chromatic"
        case .sharpen: "sharpen"
        case .pixelate: "pixelate"
        }
    }
}

/// Runs chains of full-screen post-process passes, ping-ponging between pooled render targets.
public final class PostProcessor {
    private struct Uniforms {
        var texelSize: SIMD2<Float>
        var direction: SIMD2<Float>
        var params: SIMD4<Float>
    }

    private let device: any MTLDevice
    private let library: any MTLLibrary
    private var pipelines: [String: any MTLRenderPipelineState] = [:]
    private let sampler: any MTLSamplerState
    private let log = Logger(subsystem: "app.diorama", category: "post")

    public init(device: any MTLDevice) throws {
        self.device = device
        library = try device.makeLibrary(source: Self.shaderSource, options: nil)

        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        // Clamp, not repeat: a blur sampling past the edge must not wrap pixels in from the
        // opposite side, which produces a bright fringe along every border.
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let state = device.makeSamplerState(descriptor: descriptor) else {
            throw RendererError.samplerCreationFailed
        }
        sampler = state
    }

    /// Apply `effects` to `source`, writing the result into `destination`.
    ///
    /// Intermediate targets come from the pool and are returned before this returns, so a chain
    /// of any length costs at most two extra framebuffers rather than one per pass.
    public func apply(
        _ effects: [PostEffect],
        source: any MTLTexture,
        destination: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        pool: FBOPool
    ) {
        // Flatten first: a separable blur is two passes, and bloom is three, so the number of
        // GPU passes is not the number of effects.
        var steps: [(function: String, params: SIMD4<Float>, direction: SIMD2<Float>)] = []
        for effect in effects {
            switch effect {
            case .gaussianBlur(let radius):
                steps.append(("post_blur", SIMD4(radius, 0, 0, 0), SIMD2(1, 0)))
                steps.append(("post_blur", SIMD4(radius, 0, 0, 0), SIMD2(0, 1)))
            case .bloom(let threshold, let intensity):
                steps.append(("post_bright", SIMD4(threshold, 0, 0, 0), .zero))
                steps.append(("post_blur", SIMD4(6, 0, 0, 0), SIMD2(1, 0)))
                steps.append(("post_blur", SIMD4(6, 0, 0, 0), SIMD2(0, 1)))
                steps.append(("post_bloom_combine", SIMD4(intensity, 0, 0, 0), .zero))
            case .vignette(let intensity):
                steps.append(("post_vignette", SIMD4(intensity, 0, 0, 0), .zero))
            case .chromaticAberration(let amount):
                steps.append(("post_chromatic", SIMD4(amount, 0, 0, 0), .zero))
            case .sharpen(let amount):
                steps.append(("post_sharpen", SIMD4(amount, 0, 0, 0), .zero))
            case .pixelate(let size):
                steps.append(("post_pixelate", SIMD4(max(1, size), 0, 0, 0), .zero))
            }
        }

        guard !steps.isEmpty else {
            copy(source, to: destination, commandBuffer: commandBuffer)
            return
        }

        // Bloom's combine step needs the untouched original, which the ping-pong has long since
        // overwritten. Keep a copy only when something actually asks for it.
        var originalCopy: PooledTexture?
        if steps.contains(where: { $0.function == "post_bloom_combine" }) {
            originalCopy = pool.acquire(
                width: source.width, height: source.height, pixelFormat: source.pixelFormat
            )
            if let originalCopy {
                copy(source, to: originalCopy.texture, commandBuffer: commandBuffer)
            }
        }
        defer { if let originalCopy { pool.release(originalCopy) } }

        var current: any MTLTexture = source
        var scratch: PooledTexture?

        for (index, step) in steps.enumerated() {
            let isLast = index == steps.count - 1
            let target: any MTLTexture

            if isLast {
                target = destination
            } else {
                guard let pooled = pool.acquire(
                    width: source.width, height: source.height, pixelFormat: source.pixelFormat
                ) else {
                    // Out of memory mid-chain: emit what we have rather than a black frame.
                    copy(current, to: destination, commandBuffer: commandBuffer)
                    if let scratch { pool.release(scratch) }
                    return
                }
                target = pooled.texture
                if let previous = scratch { pool.release(previous) }
                scratch = pooled
            }

            encode(
                function: step.function,
                input: current,
                secondary: originalCopy?.texture,
                target: target,
                params: step.params,
                direction: step.direction,
                commandBuffer: commandBuffer
            )
            current = target
        }

        if let scratch { pool.release(scratch) }
    }

    private func encode(
        function: String,
        input: any MTLTexture,
        secondary: (any MTLTexture)?,
        target: any MTLTexture,
        params: SIMD4<Float>,
        direction: SIMD2<Float>,
        commandBuffer: any MTLCommandBuffer
    ) {
        guard let pipeline = pipeline(named: function, pixelFormat: target.pixelFormat) else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        // Every pass writes the whole target, so there is nothing worth loading first.
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.label = function

        var uniforms = Uniforms(
            texelSize: SIMD2(1 / Float(input.width), 1 / Float(input.height)),
            direction: direction,
            params: params
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentTexture(secondary ?? input, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Copies `source` onto `destination` by drawing it, never by blitting.
    ///
    /// A blit needs both textures exactly the same size, and the pool hands out textures
    /// rounded up to its buckets — a 1512x982 frame accumulates in a 1536x1024 target — so the
    /// size check failed on every such frame and the copy was silently skipped. It also cannot
    /// write a drawable at all: a desktop layer's textures are framebuffer-only. Between them,
    /// a scene with a per-layer effect and no scene-wide one delivered a transparent frame to
    /// the desktop, which showed as black. A draw samples 0..1 and fills whatever it is given.
    private func copy(
        _ source: any MTLTexture, to destination: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) {
        encode(
            function: "post_copy", input: source, secondary: nil, target: destination,
            params: .zero, direction: .zero, commandBuffer: commandBuffer
        )
    }

    private func pipeline(named name: String, pixelFormat: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        let key = "\(name)-\(pixelFormat.rawValue)"
        if let existing = pipelines[key] { return existing }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = name
        descriptor.vertexFunction = library.makeFunction(name: "post_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: name)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        do {
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = state
            return state
        } catch {
            log.error("post pipeline \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 texelSize;
        float2 direction;
        float4 params;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Fullscreen triangle: three vertices, no buffer, and no seam down the diagonal.
    vertex VertexOut post_vertex(uint vid [[vertex_id]]) {
        float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        VertexOut out;
        out.position = float4(positions[vid], 0, 1);
        out.uv = positions[vid] * 0.5 + 0.5;
        out.uv.y = 1.0 - out.uv.y;
        return out;
    }

    fragment float4 post_copy(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler samp [[sampler(0)]]) {
        return tex.sample(samp, in.uv);
    }

    // Nine-tap Gaussian, run separably so a radius-N blur costs 2N samples rather than N*N.
    fragment float4 post_blur(VertexOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> tex [[texture(0)]],
                              sampler samp [[sampler(0)]]) {
        const float weights[5] = { 0.227027, 0.194595, 0.121622, 0.054054, 0.016216 };
        float2 step = u.direction * u.texelSize * max(u.params.x, 0.0);
        float4 sum = tex.sample(samp, in.uv) * weights[0];
        for (int i = 1; i < 5; ++i) {
            sum += tex.sample(samp, in.uv + step * float(i)) * weights[i];
            sum += tex.sample(samp, in.uv - step * float(i)) * weights[i];
        }
        return sum;
    }

    fragment float4 post_bright(VertexOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                texture2d<float> tex [[texture(0)]],
                                sampler samp [[sampler(0)]]) {
        float4 color = tex.sample(samp, in.uv);
        float luma = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
        float keep = smoothstep(u.params.x, u.params.x + 0.15, luma);
        return float4(color.rgb * keep, color.a);
    }

    fragment float4 post_bloom_combine(VertexOut in [[stage_in]],
                                       constant Uniforms &u [[buffer(0)]],
                                       texture2d<float> blurred [[texture(0)]],
                                       texture2d<float> original [[texture(1)]],
                                       sampler samp [[sampler(0)]]) {
        float4 base = original.sample(samp, in.uv);
        float4 glow = blurred.sample(samp, in.uv);
        return float4(base.rgb + glow.rgb * u.params.x, base.a);
    }

    fragment float4 post_vignette(VertexOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]],
                                  sampler samp [[sampler(0)]]) {
        float4 color = tex.sample(samp, in.uv);
        float2 centered = in.uv - 0.5;
        float falloff = 1.0 - smoothstep(0.25, 0.75, length(centered)) * u.params.x;
        return float4(color.rgb * falloff, color.a);
    }

    fragment float4 post_chromatic(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler samp [[sampler(0)]]) {
        float2 offset = (in.uv - 0.5) * u.params.x * 0.01;
        float r = tex.sample(samp, in.uv + offset).r;
        float4 g = tex.sample(samp, in.uv);
        float b = tex.sample(samp, in.uv - offset).b;
        return float4(r, g.g, b, g.a);
    }

    fragment float4 post_sharpen(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler samp [[sampler(0)]]) {
        float4 center = tex.sample(samp, in.uv);
        float4 sum = tex.sample(samp, in.uv + float2(u.texelSize.x, 0))
                   + tex.sample(samp, in.uv - float2(u.texelSize.x, 0))
                   + tex.sample(samp, in.uv + float2(0, u.texelSize.y))
                   + tex.sample(samp, in.uv - float2(0, u.texelSize.y));
        float3 sharpened = center.rgb + (center.rgb * 4.0 - sum.rgb) * u.params.x;
        return float4(clamp(sharpened, 0.0, 1.0), center.a);
    }

    fragment float4 post_pixelate(VertexOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]],
                                  sampler samp [[sampler(0)]]) {
        float2 blockUV = u.texelSize * u.params.x;
        float2 snapped = floor(in.uv / blockUV) * blockUV + blockUV * 0.5;
        return tex.sample(samp, snapped);
    }
    """
}
