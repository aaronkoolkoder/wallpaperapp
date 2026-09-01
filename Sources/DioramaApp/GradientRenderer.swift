import Metal
import QuartzCore
import os
import simd

/// A self-contained animated gradient, used to prove the M0 exit criteria end to end: a surface
/// that renders behind desktop icons on every display, ticks from the display link, and stops
/// dead when covered.
///
/// This is scaffolding. It is replaced by the real render graph in `MetalRenderer` once wallpaper
/// backends land, and exists now so the window, display-link and power plumbing can be verified
/// independently of any Wallpaper Engine content.
final class GradientRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var startTime = CACurrentMediaTime()

    /// Rolling frame statistics, surfaced in the menu bar so the power behaviour is observable.
    ///
    /// Written from Metal's completion handler, which runs on a driver thread, and read from the
    /// main actor when the menu opens. A lock rather than an actor hop: the completion handler is
    /// on the GPU's critical path and should not be scheduling tasks.
    private let stats = OSAllocatedUnfairLock(initialState: Stats())

    struct Stats: Sendable {
        var framesRendered: UInt64 = 0
        var lastGPUMilliseconds: Double = 0
    }

    var framesRendered: UInt64 { stats.withLock(\.framesRendered) }
    var lastGPUMilliseconds: Double { stats.withLock(\.lastGPUMilliseconds) }

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut { float4 position [[position]]; float2 uv; };

        // Fullscreen triangle. Cheaper than a quad: three vertices, no index buffer, and no
        // diagonal seam where the two triangles of a quad meet.
        vertex VertexOut gradient_vertex(uint vid [[vertex_id]]) {
            float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            VertexOut out;
            out.position = float4(positions[vid], 0.0, 1.0);
            out.uv = positions[vid] * 0.5 + 0.5;
            return out;
        }

        fragment float4 gradient_fragment(VertexOut in [[stage_in]],
                                          constant float &time [[buffer(0)]]) {
            float2 uv = in.uv;
            float wave = sin(uv.x * 3.0 + time * 0.4) * 0.5 + 0.5;
            float3 a = float3(0.09, 0.10, 0.20);
            float3 b = float3(0.35, 0.16, 0.44);
            float3 c = float3(0.10, 0.32, 0.42);
            float3 color = mix(mix(a, b, uv.y), c, wave * 0.6);
            // Subtle dither breaks up banding on a large smooth gradient, which is very visible
            // on a 5K display at 8 bits per channel.
            float dither = fract(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453) / 255.0;
            return float4(color + dither, 1.0);
        }
        """

        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "gradient_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "gradient_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }
    }

    func render(to layer: CAMetalLayer) {
        guard let drawable = layer.nextDrawable() else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var time = Float(CACurrentMediaTime() - startTime)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&time, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        let stats = self.stats
        buffer.addCompletedHandler { completed in
            let elapsed = (completed.gpuEndTime - completed.gpuStartTime) * 1000
            stats.withLock { state in
                state.lastGPUMilliseconds = elapsed
                state.framesRendered &+= 1
            }
        }

        buffer.present(drawable)
        buffer.commit()
    }
}
