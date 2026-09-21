import CoreGraphics
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
import WEFormat
@testable import SceneEngine

@Suite("TextureLoader")
struct TextureLoaderTests {

    @Test("Format 0 is RGBA in memory, whatever this code base calls it")
    func formatZeroIsRGBA() {
        // This test used to pin BGRA — the original assumption, never measured — and so
        // guarded the bug that put Green Hill Zone under a red sky. Checked since against real
        // content three ways: a blue sky's texture is heavy in byte 2, a flow map's unused
        // blue channel is byte 2 and exactly zero, and repkg reads the format as RGBA8888.
        #expect(TextureLoader.pixelFormat(for: .argb8888) == .rgba8Unorm)
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

    /// A 2x2 PNG, straight alpha as every PNG is, every pixel the given colour.
    private func png(r: UInt8, g: UInt8, b: UInt8, a: UInt8) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: 2 * 2 * 4)
        for index in 0 ..< 4 { pixels.replaceSubrange(index * 4 ..< index * 4 + 4, with: [r, g, b, a]) }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// Wraps an encoded image in a TEXB0003 container, as Wallpaper Engine stores one.
    private func tex(wrapping encoded: Data) -> Data {
        var data = Data()
        func magic(_ s: String) { data.append(Data(s.utf8)); data.append(0) }
        func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        magic("TEXV0005"); magic("TEXI0001")
        i32(0); i32(2)                   // format 0, clamped
        i32(2); i32(2); i32(2); i32(2)
        i32(0)
        magic("TEXB0003")
        i32(1); i32(13)                  // one image, FreeImage PNG
        i32(1)                           // one mipmap
        i32(2); i32(2); i32(0); i32(0); i32(Int32(encoded.count))
        data.append(encoded)
        return data
    }

    @Test("A PNG texture keeps straight alpha, not CoreGraphics' premultiplied copy")
    func encodedImagesStayStraightAlpha() throws {
        // Every texture the renderer samples is treated as straight alpha: the built-in shader
        // premultiplies after sampling. Uploaded premultiplied, a half-transparent pixel came
        // out at a quarter of its colour — a dark fringe around every soft edge.
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let texture = try TextureLoader().makeTexture(
            from: try TEXTexture(data: tex(wrapping: try png(r: 200, g: 100, b: 50, a: 128))),
            device: device
        )

        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        let (b, g, r, a) = (pixel[0], pixel[1], pixel[2], pixel[3])   // BGRA
        #expect(abs(Int(a) - 128) <= 1)
        #expect(abs(Int(r) - 200) <= 3 && abs(Int(g) - 100) <= 3 && abs(Int(b) - 50) <= 3,
                "expected straight (200, 100, 50), got (\(r), \(g), \(b)) — premultiplied would be (100, 50, 25)")
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
