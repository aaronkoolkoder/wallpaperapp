import Compression
import Foundation
import Testing
@testable import WEFormat

/// Synthesizes `.tex` buffers. Same rationale as ``PKGBuilder``: no Workshop content in the repo.
struct TEXBuilder {
    var version = "TEXV0005"
    var imageVersion = "TEXI0001"
    var containerVersion = "TEXB0003"
    var format: Int32 = TextureFormat.argb8888.rawValue
    var flags: Int32 = 0
    var textureWidth: Int32 = 4
    var textureHeight: Int32 = 4
    var imageWidth: Int32 = 4
    var imageHeight: Int32 = 4
    /// -1 means "no FreeImage format", i.e. the mipmaps hold raw or LZ4-compressed pixels.
    /// A value of 0 or above means each level is an encoded image file — 2 is JPEG, 13 is PNG.
    /// Defaulting to 0 made every fixture claim to be a BMP, which is not what a raw texture is.
    var freeImageFormat: Int32 = -1
    /// TEXB0004's extra field: set means the payload is an MP4 rather than an image.
    var isVideo: Int32 = 0
    var mipmaps: [(w: Int32, h: Int32, payload: Data, compress: Bool)] = []
    /// Further pages of a multi-image animation, each its own mip chain.
    var extraImages: [[(w: Int32, h: Int32, payload: Data, compress: Bool)]] = []
    /// Writes each level the way a video texture stores its MP4: no pixel size, the file's
    /// length as `compressedSize`.
    var videoLayout = false
    /// A `TEXS` table as real files write it. `rect` is x, y, width, widthY, heightX, height.
    var spriteSheet: (
        version: String, gif: (Int32, Int32)?, frames: [(image: Int32, duration: Float, rect: [Float])]
    )?

    func build() -> Data {
        var data = Data()
        data.appendMagic(version)
        data.appendMagic(imageVersion)
        data.appendInt32(format)
        data.appendInt32(flags)
        data.appendInt32(textureWidth)
        data.appendInt32(textureHeight)
        data.appendInt32(imageWidth)
        data.appendInt32(imageHeight)
        data.appendInt32(0)                     // unknown header field

        data.appendMagic(containerVersion)
        data.appendInt32(Int32(1 + extraImages.count))     // image count
        if containerVersion == "TEXB0004" {
            data.appendInt32(freeImageFormat)
            data.appendInt32(isVideo)
        } else if containerVersion == "TEXB0003" {
            data.appendInt32(freeImageFormat)
        }

        for image in [mipmaps] + extraImages {
            data.appendInt32(Int32(image.count))
            for mip in image {
                data.appendInt32(mip.w)
                data.appendInt32(mip.h)
                if videoLayout {
                    data.appendInt32(0)
                    data.appendInt32(0)
                    data.appendInt32(Int32(mip.payload.count))
                    data.append(mip.payload)
                } else if mip.compress {
                    let compressed = Self.lz4(mip.payload)
                    data.appendInt32(1)
                    data.appendInt32(Int32(mip.payload.count))
                    data.appendInt32(Int32(compressed.count))
                    data.append(compressed)
                } else {
                    data.appendInt32(0)
                    data.appendInt32(Int32(mip.payload.count))
                    data.appendInt32(Int32(mip.payload.count))
                    data.append(mip.payload)
                }
            }
        }

        if let sheet = spriteSheet {
            data.appendMagic(sheet.version)
            data.appendInt32(Int32(sheet.frames.count))
            if let gif = sheet.gif {
                data.appendInt32(gif.0)
                data.appendInt32(gif.1)
            }
            for frame in sheet.frames {
                data.appendInt32(frame.image)
                data.appendFloat(frame.duration)
                for component in frame.rect {
                    if sheet.version == "TEXS0001" {
                        data.appendInt32(Int32(component))
                    } else {
                        data.appendFloat(component)
                    }
                }
            }
        }
        return data
    }

    static func lz4(_ input: Data) -> Data {
        let capacity = max(64, input.count * 2)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                compression_encode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count,
                    nil, COMPRESSION_LZ4_RAW
                )
            }
        }
        return output.prefix(written)
    }
}

@Suite("TEXTexture")
struct TEXTextureTests {

    private func rgba(_ count: Int) -> Data {
        Data((0 ..< count * 4).map { UInt8($0 % 251) })
    }

    // MARK: - Container revisions

    @Test("A TEXB0004 texture reads like TEXB0003 when it holds an image")
    func readsRevisionFour() throws {
        // Seen in real content as a whole wallpaper's background. Refusing the revision drew
        // that background as the white placeholder.
        var builder = TEXBuilder()
        builder.containerVersion = "TEXB0004"
        builder.mipmaps = [(4, 4, rgba(16), false), (2, 2, rgba(4), false)]
        let texture = try TEXTexture(data: builder.build())

        #expect(texture.containerVersion == "TEXB0004")
        #expect(texture.mipmaps.map(\.width) == [4, 2])
        #expect(texture.mipmaps[0].data == rgba(16))
        #expect(texture.mipmaps[1].data == rgba(4))
    }

    @Test("A TEXB0004 encoded image keeps its FreeImage format")
    func revisionFourEncodedImage() throws {
        var builder = TEXBuilder()
        builder.containerVersion = "TEXB0004"
        builder.freeImageFormat = 13            // PNG
        builder.mipmaps = [(4, 4, Data([0x89, 0x50, 0x4E, 0x47]), false)]
        let texture = try TEXTexture(data: builder.build())
        #expect(texture.freeImageFormat == 13)
        #expect(texture.mipmaps.first?.isEncodedImage == true)
    }

    @Test("A TEXB0004 video texture hands back its MP4")
    func revisionFourVideo() throws {
        var builder = TEXBuilder()
        builder.containerVersion = "TEXB0004"
        builder.isVideo = 1
        builder.videoLayout = true
        let movie = Data("....ftypmp42 not really a movie".utf8)
        builder.mipmaps = [(640, 444, movie, false)]
        let texture = try TEXTexture(data: builder.build())
        #expect(texture.isVideo)
        #expect(texture.videoData == movie)
    }

    @Test("A video flagged in the header of a TEXB0003 container hands back its MP4")
    func flaggedVideo() throws {
        // Real content: a logo and an animated character, each an MP4 inside an ordinary
        // TEXB0003 container with flag 0x20 set and uncompressedSize 0. Refused as a corrupt
        // field, each layer drew as a white square.
        var builder = TEXBuilder()
        builder.flags = 0x22                 // clampUVs + isVideo
        builder.videoLayout = true
        let movie = Data("\u{0}\u{0}\u{0} ftypisom".utf8)
        builder.mipmaps = [(640, 444, movie, false)]
        let texture = try TEXTexture(data: builder.build())
        #expect(texture.isVideo)
        #expect(texture.flags.contains(.isVideo))
        #expect(texture.videoData == movie)
    }

    @Test("An image texture has no video data")
    func imageIsNotVideo() throws {
        var builder = TEXBuilder()
        builder.mipmaps = [(4, 4, rgba(16), false)]
        let texture = try TEXTexture(data: builder.build())
        #expect(!texture.isVideo)
        #expect(texture.videoData == nil)
    }

    // MARK: - Round trip

    @Test("Reads an uncompressed RGBA texture")
    func uncompressedRGBA() throws {
        var builder = TEXBuilder()
        let pixels = rgba(16)
        builder.mipmaps = [(4, 4, pixels, false)]

        let texture = try TEXTexture(data: builder.build())
        #expect(texture.version == "TEXV0005")
        #expect(texture.format == .argb8888)
        #expect(texture.mipmaps.count == 1)
        #expect(texture.mipmaps[0].width == 4)
        #expect(texture.mipmaps[0].data == pixels)
        #expect(texture.mipmaps[0].wasCompressed == false)
    }

    @Test("Decompresses an LZ4 mipmap and recovers the exact bytes")
    func lz4RoundTrip() throws {
        var builder = TEXBuilder()
        // Highly repetitive so LZ4 actually shrinks it; random data can expand under LZ4_RAW
        // and would test the wrong thing.
        let pixels = Data(repeating: 0xAB, count: 4096)
        builder.textureWidth = 32; builder.textureHeight = 32
        builder.imageWidth = 32; builder.imageHeight = 32
        builder.mipmaps = [(32, 32, pixels, true)]

        let texture = try TEXTexture(data: builder.build())
        #expect(texture.mipmaps[0].wasCompressed == true)
        #expect(texture.mipmaps[0].data == pixels)
    }

    @Test("Reads a full mipmap chain")
    func mipmapChain() throws {
        var builder = TEXBuilder()
        builder.textureWidth = 8; builder.textureHeight = 8
        builder.imageWidth = 8; builder.imageHeight = 8
        builder.mipmaps = [
            (8, 8, rgba(64), false),
            (4, 4, rgba(16), false),
            (2, 2, rgba(4), false),
            (1, 1, rgba(1), false),
        ]

        let texture = try TEXTexture(data: builder.build())
        #expect(texture.mipmaps.count == 4)
        #expect(texture.mipmaps.map(\.width) == [8, 4, 2, 1])
    }

    @Test("Supports every container revision", arguments: ["TEXB0001", "TEXB0002", "TEXB0003"])
    func containerVersions(container: String) throws {
        var builder = TEXBuilder()
        builder.containerVersion = container
        builder.mipmaps = [(4, 4, rgba(16), false)]

        let texture = try TEXTexture(data: builder.build())
        #expect(texture.containerVersion == container)
        #expect(texture.mipmaps.count == 1)
    }

    @Test(
        "Recognizes every documented pixel format",
        arguments: TextureFormat.allCases
    )
    func pixelFormats(format: TextureFormat) throws {
        var builder = TEXBuilder()
        builder.format = format.rawValue
        builder.mipmaps = [(4, 4, rgba(16), false)]

        let texture = try TEXTexture(data: builder.build())
        #expect(texture.format == format)
    }

    @Test("Block-compressed formats are flagged as such")
    func blockCompressedFlag() {
        // Apple Silicon uploads BC blocks directly, so this flag decides whether a CPU decode
        // path is needed at all (PLAN.md §4.3).
        #expect(TextureFormat.dxt1.isBlockCompressed)
        #expect(TextureFormat.dxt3.isBlockCompressed)
        #expect(TextureFormat.dxt5.isBlockCompressed)
        #expect(TextureFormat.argb8888.isBlockCompressed == false)
        #expect(TextureFormat.r8.isBlockCompressed == false)
    }

    @Test("Decodes texture flags")
    func textureFlags() throws {
        var builder = TEXBuilder()
        builder.flags = 1 | 4        // interpolation + isGif
        builder.mipmaps = [(4, 4, rgba(16), false)]

        let texture = try TEXTexture(data: builder.build())
        #expect(texture.flags.contains(.interpolation))
        #expect(texture.flags.contains(.isGif))
        #expect(texture.flags.contains(.clampUVs) == false)
    }

    @Test("Reads a TEXS0002 frame table: seconds and a pixel rectangle per frame")
    func spriteSheet() throws {
        // Shaped like a real 4-frame strip: 3072x896 frames stacked in a 4096x4096 atlas.
        var builder = TEXBuilder()
        builder.flags = 4
        builder.mipmaps = [(4, 4, rgba(16), false)]
        builder.spriteSheet = ("TEXS0002", nil, [
            (0, 0.1, [0, 0, 3072, 0, 0, 896]),
            (0, 0.1, [0, 896, 3072, 0, 0, 896]),
        ])

        let texture = try TEXTexture(data: builder.build())
        let sheet = try #require(texture.spriteSheet)
        #expect(sheet.frames.count == 2)
        #expect(sheet.frames[0].duration == 0.1)
        #expect(sheet.frames[1].y == 896)
        #expect(sheet.frames[1].width == 3072)
        #expect(sheet.frames[1].height == 896)
        #expect(abs(sheet.loopDuration - 0.2) < 0.0001)
        #expect(texture.warnings.isEmpty)
    }

    @Test("Reads a TEXS0003 table, whose frame count comes before the GIF's size")
    func spriteSheetRevisionThree() throws {
        var builder = TEXBuilder()
        builder.flags = 4
        builder.mipmaps = [(4, 4, rgba(16), false)]
        builder.spriteSheet = ("TEXS0003", (200, 205), [
            (0, 0.042, [0, 0, 200, 0, 0, 205]),
            (0, 0.042, [200, 0, 200, 0, 0, 205]),
            (0, 0.042, [400, 0, 200, 0, 0, 205]),
        ])

        let texture = try TEXTexture(data: builder.build())
        let sheet = try #require(texture.spriteSheet)
        #expect(sheet.gifWidth == 200)
        #expect(sheet.gifHeight == 205)
        #expect(sheet.frames.map(\.x) == [0, 200, 400])
    }

    @Test("Reads TEXS0001's integer rectangles")
    func spriteSheetRevisionOne() throws {
        var builder = TEXBuilder()
        builder.mipmaps = [(4, 4, rgba(16), false)]
        builder.spriteSheet = ("TEXS0001", nil, [(0, 0.5, [2, 0, 2, 0, 0, 4])])
        let sheet = try #require(try TEXTexture(data: builder.build()).spriteSheet)
        #expect(sheet.frames[0].x == 2)
        #expect(sheet.frames[0].height == 4)
    }

    @Test("Every page of a multi-image animation is read, and frames say which page")
    func multipleImages() throws {
        // Real content: 43 frames of 1080p in two 8192x8192 pages. Only the first page used
        // to be read, which left the reader inside the second when it looked for the frames.
        var builder = TEXBuilder()
        builder.flags = 4
        builder.mipmaps = [(4, 4, rgba(16), false), (2, 2, rgba(4), false)]
        builder.extraImages = [[(4, 4, Data(rgba(16).map { $0 ^ 0xFF }), true)]]
        builder.spriteSheet = ("TEXS0003", (4, 4), [
            (0, 0.15, [0, 0, 4, 0, 0, 4]),
            (1, 0.15, [0, 0, 4, 0, 0, 4]),
        ])

        let texture = try TEXTexture(data: builder.build())
        #expect(texture.images.count == 2)
        #expect(texture.images[0].count == 2)
        #expect(texture.images[1][0].data == Data(rgba(16).map { $0 ^ 0xFF }))
        #expect(texture.mipmaps == texture.images[0])
        let sheet = try #require(texture.spriteSheet)
        #expect(sheet.frames.map(\.imageIndex) == [0, 1])
    }

    @Test("A frame table that does not fill the file is ignored with a warning")
    func inconsistentSpriteTable() throws {
        var builder = TEXBuilder()
        builder.mipmaps = [(4, 4, rgba(16), false)]
        builder.spriteSheet = ("TEXS0002", nil, [(0, 0.1, [0, 0, 2, 0, 0, 2])])
        var data = builder.build()
        data.append(contentsOf: [0, 0, 0, 0])
        let texture = try TEXTexture(data: data)
        #expect(texture.spriteSheet == nil)
        #expect(texture.warnings.contains { $0.contains("TEXS0002") })
    }

    @Test("A texture with no sprite sheet reports none")
    func noSpriteSheet() throws {
        var builder = TEXBuilder()
        builder.mipmaps = [(4, 4, rgba(16), false)]
        let texture = try TEXTexture(data: builder.build())
        #expect(texture.spriteSheet == nil)
    }

    // MARK: - Hostile input

    @Test("Rejects a wrong file magic")
    func badMagic() {
        var builder = TEXBuilder()
        builder.version = "PNGV0001"
        builder.mipmaps = [(4, 4, rgba(16), false)]
        #expect(throws: WEError.self) { try TEXTexture(data: builder.build()) }
    }

    @Test("Rejects a wrong image magic")
    func badImageMagic() {
        var builder = TEXBuilder()
        builder.imageVersion = "XXXX0001"
        builder.mipmaps = [(4, 4, rgba(16), false)]
        #expect(throws: WEError.self) { try TEXTexture(data: builder.build()) }
    }

    @Test("Rejects an LZ4 block whose declared size does not match what it decodes to")
    func lz4SizeMismatch() {
        var data = Data()
        data.appendMagic("TEXV0005")
        data.appendMagic("TEXI0001")
        data.appendInt32(0); data.appendInt32(0)
        data.appendInt32(4); data.appendInt32(4)
        data.appendInt32(4); data.appendInt32(4)
        data.appendInt32(0)
        data.appendMagic("TEXB0003")
        data.appendInt32(0)
        data.appendInt32(-1)             // freeImageFormat: raw pixels, not an encoded image
        data.appendInt32(1)
        data.appendInt32(4); data.appendInt32(4)
        data.appendInt32(1)              // compressed
        data.appendInt32(999_999)        // claims a huge decompressed size
        data.appendInt32(4)
        data.append(Data([0, 0, 0, 0]))  // not valid LZ4 for that size

        #expect(throws: WEError.self) { try TEXTexture(data: data) }
    }

    @Test("Rejects absurd dimensions")
    func absurdDimensions() {
        var builder = TEXBuilder()
        builder.textureWidth = Int32.max
        builder.mipmaps = [(4, 4, rgba(16), false)]
        #expect(throws: WEError.self) { try TEXTexture(data: builder.build()) }
    }

    @Test("Rejects a negative dimension")
    func negativeDimension() {
        var builder = TEXBuilder()
        builder.imageHeight = -1
        builder.mipmaps = [(4, 4, rgba(16), false)]
        #expect(throws: WEError.self) { try TEXTexture(data: builder.build()) }
    }

    @Test("Rejects an absurd mipmap count")
    func absurdMipmapCount() {
        var data = Data()
        data.appendMagic("TEXV0005")
        data.appendMagic("TEXI0001")
        data.appendInt32(0); data.appendInt32(0)
        data.appendInt32(4); data.appendInt32(4)
        data.appendInt32(4); data.appendInt32(4)
        data.appendInt32(0)
        data.appendMagic("TEXB0003")
        data.appendInt32(0); data.appendInt32(0)
        data.appendInt32(Int32.max)

        #expect(throws: WEError.self) { try TEXTexture(data: data) }
    }

    @Test("Every prefix of a valid texture fails cleanly rather than trapping")
    func truncation() throws {
        var builder = TEXBuilder()
        builder.mipmaps = [(4, 4, rgba(16), false)]
        let full = builder.build()

        for cut in stride(from: 1, to: full.count, by: 2) {
            #expect(throws: (any Error).self) { try TEXTexture(data: Data(full.prefix(cut))) }
        }
    }

    @Test("An empty buffer fails cleanly")
    func emptyBuffer() {
        #expect(throws: (any Error).self) { try TEXTexture(data: Data()) }
    }

    @Test("A FreeImage-encoded mipmap is kept as a file, not read as pixels")
    func acceptsEncodedMipmap() throws {
        // Wallpaper Engine stores plenty of textures as a PNG or JPEG per level. Such a level
        // declares uncompressedSize 0 because the field does not apply — the byte count is the
        // file's. Treating that as corruption rejected 29 of the 77 textures in a real library.
        var builder = TEXBuilder()
        builder.freeImageFormat = 13          // FreeImage's PNG
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
        builder.mipmaps = [(w: 4, h: 4, payload: png, compress: false)]
        // An encoded level stores its length in compressedSize and leaves uncompressedSize 0,
        // which the builder does not model, so the bytes are laid out here directly.
        var data = Data()
        data.appendMagic("TEXV0005"); data.appendMagic("TEXI0001")
        data.appendInt32(0); data.appendInt32(0)
        data.appendInt32(4); data.appendInt32(4)
        data.appendInt32(4); data.appendInt32(4)
        data.appendInt32(0)
        data.appendMagic("TEXB0003")
        data.appendInt32(0)
        data.appendInt32(13)                  // freeImageFormat: PNG
        data.appendInt32(1)                   // one mipmap
        data.appendInt32(4); data.appendInt32(4)
        data.appendInt32(0)                   // not LZ4
        data.appendInt32(0)                   // uncompressedSize: does not apply
        data.appendInt32(Int32(png.count))    // the file's length
        data.append(png)

        let texture = try TEXTexture(data: data)
        let mip = try #require(texture.mipmaps.first)
        #expect(mip.isEncodedImage)
        #expect(mip.data == png)
    }

    @Test("A raw mipmap is still rejected when it declares no size")
    func stillRejectsSizelessRawMipmap() throws {
        // The relaxation must apply only to encoded levels. A raw one claiming zero bytes is
        // still corrupt, and letting it through would hand the loader an empty pixel buffer.
        var data = Data()
        data.appendMagic("TEXV0005"); data.appendMagic("TEXI0001")
        data.appendInt32(0); data.appendInt32(0)
        data.appendInt32(4); data.appendInt32(4)
        data.appendInt32(4); data.appendInt32(4)
        data.appendInt32(0)
        data.appendMagic("TEXB0003")
        data.appendInt32(0)
        data.appendInt32(-1)                  // no FreeImage format: raw pixels
        data.appendInt32(1)
        data.appendInt32(4); data.appendInt32(4)
        data.appendInt32(0)
        data.appendInt32(0)                   // uncompressedSize 0 on a raw level: corrupt
        data.appendInt32(0)

        #expect(throws: WEError.self) { try TEXTexture(data: data) }
    }
}
