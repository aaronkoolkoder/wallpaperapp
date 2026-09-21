import Metal
import Testing
@testable import MetalRenderer

/// The copy at the end of every effect chain with nothing left to apply.
///
/// It is the last thing between a composed frame and the desktop, so a copy that silently does
/// nothing hands the display a transparent frame — which an opaque desktop window shows as
/// black. That is what it did for every scene with a layer effect and no scene-wide one.
@Suite(
    "PostProcessor copy",
    .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a GPU")
)
struct PostProcessorCopyTests {

    private func texture(
        _ device: any MTLDevice, width: Int, height: Int, readable: Bool = false
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = readable ? .shared : .private
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    /// Fills `target` with one colour using a clear, the cheapest way to put known pixels there.
    private func fill(
        _ target: any MTLTexture, red: Double, in buffer: any MTLCommandBuffer
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: red, green: 0, blue: 0, alpha: 1)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }

    private func centre(of texture: any MTLTexture) -> (r: UInt8, a: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(
            &pixel, bytesPerRow: 4,
            from: MTLRegionMake2D(texture.width / 2, texture.height / 2, 1, 1), mipmapLevel: 0
        )
        return (pixel[2], pixel[3])   // BGRA
    }

    @Test("An empty chain copies a pool-sized frame onto a smaller destination",
          arguments: [(64, 32), (1536, 1512), (32, 32)])
    func copiesAcrossSizes(sizes: (source: Int, destination: Int)) throws {
        // The pool rounds sizes up to its buckets, so a frame accumulates in a texture larger
        // than the drawable it is bound for: 1536 wide for a 1512-wide display. A blit refuses
        // mismatched sizes, and the copy was skipped on every such frame.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let post = try PostProcessor(device: device)
        let pool = FBOPool(device: device)

        let source = try texture(device, width: sizes.source, height: sizes.source)
        let destination = try texture(
            device, width: sizes.destination, height: sizes.destination, readable: true
        )

        let buffer = try #require(queue.makeCommandBuffer())
        fill(source, red: 1, in: buffer)
        post.apply([], source: source, destination: destination, commandBuffer: buffer, pool: pool)
        buffer.commit()
        buffer.waitUntilCompleted()

        let pixel = centre(of: destination)
        #expect(pixel.r > 240 && pixel.a > 240,
                "the frame never reached the destination: got r=\(pixel.r) a=\(pixel.a)")
    }
}
