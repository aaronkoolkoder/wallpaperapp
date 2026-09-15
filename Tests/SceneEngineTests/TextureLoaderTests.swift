import Metal
import Testing
import WEFormat
@testable import SceneEngine

@Suite("TextureLoader")
struct TextureLoaderTests {

    @Test("ARGB8888 maps to BGRA, not RGBA")
    func argbMapsToBGRA() {
        // The format's name is Wallpaper Engine's own channel naming; the bytes on disk are
        // BGRA. Choosing .rgba8Unorm here swaps red and blue on every uncompressed texture, and
        // the result looks plausible rather than broken — which is exactly why it needs a test.
        #expect(TextureLoader.pixelFormat(for: .argb8888) == .bgra8Unorm)
    }

    @Test("Block-compressed formats map to their BC equivalents")
    func blockCompressedMapping() {
        #expect(TextureLoader.pixelFormat(for: .dxt1) == .bc1_rgba)
        #expect(TextureLoader.pixelFormat(for: .dxt3) == .bc2_rgba)
        #expect(TextureLoader.pixelFormat(for: .dxt5) == .bc3_rgba)
    }

    @Test("Single and dual channel formats map correctly")
    func narrowFormats() {
        #expect(TextureLoader.pixelFormat(for: .rg88) == .rg8Unorm)
        #expect(TextureLoader.pixelFormat(for: .r8) == .r8Unorm)
    }

    @Test("Uncompressed stride is pixels times bytes per pixel")
    func uncompressedStride() {
        #expect(TextureLoader.bytesPerRow(format: .argb8888, width: 256) == 1024)
        #expect(TextureLoader.bytesPerRow(format: .rg88, width: 256) == 512)
        #expect(TextureLoader.bytesPerRow(format: .r8, width: 256) == 256)
    }

    @Test("Block-compressed stride is measured in 4x4 blocks")
    func blockStride() {
        // BC1 is 8 bytes per block, BC2/BC3 are 16.
        #expect(TextureLoader.bytesPerRow(format: .dxt1, width: 256) == 64 * 8)
        #expect(TextureLoader.bytesPerRow(format: .dxt5, width: 256) == 64 * 16)
    }

    @Test("Block count rounds up for non-multiple-of-four widths")
    func blockStrideRoundsUp() {
        // A 5-pixel-wide mip still occupies two blocks. Rounding down here truncates the last
        // block of every row and skews the whole image.
        #expect(TextureLoader.bytesPerRow(format: .dxt1, width: 5) == 2 * 8)
        #expect(TextureLoader.bytesPerRow(format: .dxt1, width: 1) == 1 * 8)
        #expect(TextureLoader.bytesPerRow(format: .dxt5, width: 6) == 2 * 16)
    }

    @Test("A texture declaring zero mipmaps is rejected rather than yielding an empty texture")
    func noMipmapsRejected() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        var data = Data()
        func magic(_ s: String) { data.append(Data(s.utf8)); data.append(0) }
        func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        magic("TEXV0005"); magic("TEXI0001")
        i32(0); i32(0)              // format argb8888, no flags
        i32(4); i32(4); i32(4); i32(4)
        i32(0)                       // unknown
        magic("TEXB0003")
        i32(0); i32(0)               // unknown, freeImageFormat
        i32(0)                       // zero mipmaps

        let texture = try TEXTexture(data: data)
        #expect(texture.mipmaps.isEmpty)
        #expect(throws: TextureLoader.LoadError.self) {
            try TextureLoader().makeTexture(from: texture, device: device)
        }
    }
}
