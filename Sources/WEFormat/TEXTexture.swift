import Compression
import Foundation

/// Pixel layout of a `.tex` payload.
///
/// The numbering is Wallpaper Engine's own and is deliberately sparse — values `1`, `2`,
/// `3` and `5` are not used by any file observed so far, which is why this is not a
/// contiguous enum. `DXT1`/`DXT3`/`DXT5` are BC1/BC2/BC3 block-compressed data that
/// Apple silicon can upload to Metal without a transcode.
public enum TextureFormat: Int32, Sendable, Hashable, CaseIterable {
    case argb8888 = 0
    case dxt5 = 4
    case dxt3 = 6
    case dxt1 = 7
    case rg88 = 8
    case r8 = 9

    /// Whether the payload is 4×4 block-compressed, i.e. its size is a function of the
    /// block count rather than the pixel count.
    public var isBlockCompressed: Bool {
        switch self {
        case .dxt1, .dxt3, .dxt5: return true
        case .argb8888, .rg88, .r8: return false
        }
    }
}

/// Sampler and playback hints stored in the `.tex` header.
public struct TextureFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    /// Sample with linear filtering rather than nearest.
    public static let interpolation = TextureFlags(rawValue: 1)
    /// Clamp UVs instead of repeating.
    public static let clampUVs = TextureFlags(rawValue: 2)
    /// The texture is an animation; frame timing lives in the trailing `TEXS` table.
    public static let isGif = TextureFlags(rawValue: 4)
    /// The payload is an MP4 video rather than pixels.
    public static let isVideo = TextureFlags(rawValue: 32)
}

/// One decoded mip level. Payloads are always stored decompressed here — the LZ4 wrapper
/// is a transport detail of the file, not a property of the image.
public struct TextureMipmap: Sendable, Hashable {
    public let width: Int
    public let height: Int
    /// Whether this level arrived as an LZ4 block. Kept for diagnostics; `data` is
    /// decompressed either way.
    public let wasCompressed: Bool

    /// True when `data` is an encoded image file — PNG or JPEG — rather than raw pixels.
    ///
    /// Wallpaper Engine stores plenty of textures this way, flagged by `freeImageFormat` in the
    /// `TEXB0003` header. Such a level declares `uncompressedSize` 0, because the field does not
    /// apply: the byte count is the file's. Treating that as corruption rejected 38% of the
    /// textures in a real library.
    public let isEncodedImage: Bool

    public let data: Data

    public init(
        width: Int, height: Int, wasCompressed: Bool,
        isEncodedImage: Bool = false, data: Data
    ) {
        self.width = width
        self.height = height
        self.wasCompressed = wasCompressed
        self.isEncodedImage = isEncodedImage
        self.data = data
    }
}

/// One frame of an animated texture, as stored in the trailing `TEXS` table.
///
/// Layout confirmed against all 18 animated textures in a real 59-scene library.
public struct SpriteFrame: Sendable, Hashable {

    /// Which of the container's images the frame sits in. See ``TEXTexture/images``.
    public let imageIndex: Int

    /// How long the frame shows, in seconds — 0.1 for a 10fps GIF.
    public let duration: Float

    /// The frame's rectangle in the image, in pixels from the top-left.
    public let x: Float
    public let y: Float
    public let width: Float
    public let height: Float

    /// Skew components of the rectangle: `(width, widthY)` is its x edge and
    /// `(heightX, height)` its y edge, so a rotated frame can be stored. Zero in every real file.
    public let widthY: Float
    public let heightX: Float

    public init(
        imageIndex: Int, duration: Float,
        x: Float, y: Float, width: Float, height: Float,
        widthY: Float = 0, heightX: Float = 0
    ) {
        self.imageIndex = imageIndex
        self.duration = duration
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.widthY = widthY
        self.heightX = heightX
    }
}

/// The optional animation frame table that follows the images in an animated `.tex`.
public struct SpriteSheet: Sendable, Hashable {
    /// Signature as it appeared in the file, e.g. `"TEXS0003"`.
    public let version: String
    public let frames: [SpriteFrame]
    /// The source GIF's frame size, which only `TEXS0003` records.
    public let gifWidth: Int?
    public let gifHeight: Int?

    public init(version: String, frames: [SpriteFrame], gifWidth: Int? = nil, gifHeight: Int? = nil) {
        self.version = version
        self.frames = frames
        self.gifWidth = gifWidth
        self.gifHeight = gifHeight
    }

    /// Time for one pass through every frame, in seconds.
    public var loopDuration: Float { frames.reduce(0) { $0 + max(0, $1.duration) } }
}

/// Reader for the Wallpaper Engine `.tex` texture container.
///
/// Layout, per PLAN.md §4.3:
///
/// ```text
/// "TEXV0005"\0                 // file magic
/// "TEXI0001"\0                 // extra magic
/// int32  format, flags
/// int32  textureWidth, textureHeight
/// int32  imageWidth,  imageHeight
/// int32  _unknown
/// "TEXB000{1,2,3,4}"\0         // mipmap container version
///   int32 imageCount
///   [TEXB0003+]     int32 freeImageFormat
///   [TEXB0004 only] int32 isVideo           // payload is an MP4 when set and the format is -1
/// image × imageCount {
///   int32  mipmapCount
///   mip × mipmapCount { width, height, isCompressed, uncompressedSize, compressedSize, data }
/// }
/// [optional] "TEXS000{1,2,3}"  // animated sprite frame table, see parseSpriteSheet
/// ```
///
/// Anything the reader could not make sense of but survived — an unrecognised pixel
/// format, an unparseable sprite table, trailing bytes — lands in ``warnings`` instead of
/// failing the parse, so a partially-understood texture still reports what it does know
/// to the compatibility report.
public struct TEXTexture: Sendable {

    /// Revisions of the mipmap container this reader decodes.
    public static let supportedContainerVersions = ["TEXB0001", "TEXB0002", "TEXB0003", "TEXB0004"]

    /// Revisions of the sprite table this reader decodes.
    public static let supportedSpriteVersions = ["TEXS0001", "TEXS0002", "TEXS0003"]

    /// Largest plausible dimension, used to reject nonsense before allocating.
    static let maxDimension = 65536

    /// File signature as found, e.g. `"TEXV0005"`. Other `TEXV####` revisions are accepted
    /// and recorded rather than rejected — the header has been stable across them.
    public let version: String

    /// Second signature as found, e.g. `"TEXI0001"`.
    public let imageVersion: String

    /// Mipmap container signature as found, one of ``supportedContainerVersions``.
    public let containerVersion: String

    /// `format` exactly as stored, kept so an unrecognised value is still reportable.
    public let rawFormat: Int32

    /// Decoded pixel format, or `nil` when `rawFormat` is not one this module knows.
    public let format: TextureFormat?

    public let flags: TextureFlags

    /// Allocated texture dimensions — padded to a power of two for older content.
    public let textureWidth: Int
    public let textureHeight: Int

    /// Dimensions of the meaningful image inside the texture. Equal to the texture
    /// dimensions when there is no padding.
    public let imageWidth: Int
    public let imageHeight: Int

    /// Undocumented `int32` between `imageHeight` and the container signature. Preserved
    /// verbatim; its meaning is unknown.
    public let unknownHeaderValue: Int32

    /// FreeImage format id, present only in `TEXB0003`.
    public let freeImageFormat: Int32?

    /// Mip levels of the first image, in file order, payloads already decompressed.
    public let mipmaps: [TextureMipmap]

    /// Every image's mip chain. More than one only for an animation spread over several pages;
    /// ``SpriteFrame/imageIndex`` says which page a frame is on.
    public let images: [[TextureMipmap]]

    /// Whether the payload is an MP4 rather than pixels. See ``videoData``.
    public let isVideo: Bool

    /// The MP4 file, for a video texture.
    public var videoData: Data? { isVideo ? mipmaps.first?.data : nil }

    /// Animation frames, when the file carries a `TEXS` table this reader could decode.
    public let spriteSheet: SpriteSheet?

    /// Non-fatal parse notes, suitable for the per-wallpaper compatibility report.
    public let warnings: [String]

    // MARK: - Parsing

    public init(data: Data) throws {
        var reader = BinaryReader(data)
        var warnings: [String] = []

        // --- File magics -----------------------------------------------------------
        let version = try reader.readNullTerminatedMagic(expectedLength: 8)
        guard version.hasPrefix("TEXV"), Self.hasFourDigitSuffix(version) else {
            throw WEError.badMagic(expected: "TEXV0005", found: version)
        }
        if version != "TEXV0005" {
            warnings.append("unexpected file version \(version); parsed as TEXV0005")
        }

        let imageVersion = try reader.readNullTerminatedMagic(expectedLength: 8)
        guard imageVersion.hasPrefix("TEXI"), Self.hasFourDigitSuffix(imageVersion) else {
            throw WEError.badMagic(expected: "TEXI0001", found: imageVersion)
        }

        // --- Fixed header ----------------------------------------------------------
        let rawFormat = try reader.readInt32()
        let format = TextureFormat(rawValue: rawFormat)
        if format == nil {
            warnings.append("unknown pixel format \(rawFormat); mipmap bytes left uninterpreted")
        }

        let flags = TextureFlags(rawValue: try reader.readInt32())
        let textureWidth = try Self.dimension(try reader.readInt32(), field: "textureWidth")
        let textureHeight = try Self.dimension(try reader.readInt32(), field: "textureHeight")
        let imageWidth = try Self.dimension(try reader.readInt32(), field: "imageWidth")
        let imageHeight = try Self.dimension(try reader.readInt32(), field: "imageHeight")
        let unknownHeaderValue = try reader.readInt32()

        // --- Mipmap container ------------------------------------------------------
        let containerVersion = try reader.readNullTerminatedMagic(expectedLength: 8)
        guard Self.supportedContainerVersions.contains(containerVersion) else {
            if containerVersion.hasPrefix("TEXB") {
                throw WEError.unsupportedVersion(containerVersion)
            }
            throw WEError.badMagic(expected: "TEXB0001…TEXB0004", found: containerVersion)
        }

        // Every revision starts with the image count; TEXB0003 adds a field naming the
        // FreeImage source format. Dispatching here keeps the difference in one place.
        //
        // Getting this wrong is silent and total: skipping the leading field on TEXB0001/0002
        // makes the parser read it *as* the mipmap count, so every older texture decodes to
        // garbage rather than failing loudly.
        let imageCountField = try reader.readInt32()
        var freeImageFormat: Int32?
        if containerVersion == "TEXB0003" || containerVersion == "TEXB0004" {
            freeImageFormat = try reader.readInt32()
        }

        // A video texture holds an MP4 where the pixels would be. Newer files say so in a
        // TEXB0004 field; older ones only through the header flag, inside an ordinary TEXB0003
        // container whose size fields then describe the file rather than pixels. Refusing them
        // drew each such layer as a white square.
        var isVideo = flags.contains(.isVideo)
        if containerVersion == "TEXB0004", try reader.readInt32() == 1, (freeImageFormat ?? -1) < 0 {
            isVideo = true
        }
        let isEncodedImage = !isVideo && (freeImageFormat ?? -1) >= 0

        // --- Images ----------------------------------------------------------------
        // An animation can spread its frames over more than one image — 43 frames of 1080p
        // fill two 8192x8192 pages — and each image carries its own mip chain. Reading only
        // the first left the reader inside the second one's pixels when it went looking for
        // the frame table. A count of 0 has only been seen from synthetic files; it still
        // means one image follows.
        let imageCount = try reader.validatedCount(
            max(1, imageCountField), elementStride: 4, field: "imageCount"
        )
        var images: [[TextureMipmap]] = []
        images.reserveCapacity(min(imageCount, 16))
        for _ in 0 ..< imageCount {
            images.append(
                try Self.readMipmaps(
                    &reader, isEncodedImage: isEncodedImage, isVideo: isVideo,
                    warnings: &warnings
                )
            )
        }
        let mipmaps = images.first ?? []
        // --- Optional sprite table -------------------------------------------------
        let (spriteSheet, spriteWarnings) = Self.parseSpriteSheet(&reader)
        warnings.append(contentsOf: spriteWarnings)

        self.version = version
        self.imageVersion = imageVersion
        self.containerVersion = containerVersion
        self.rawFormat = rawFormat
        self.format = format
        self.flags = flags
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.unknownHeaderValue = unknownHeaderValue
        self.freeImageFormat = freeImageFormat
        self.mipmaps = mipmaps
        self.images = images
        self.isVideo = isVideo
        self.spriteSheet = spriteSheet
        self.warnings = warnings
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    // MARK: - Derived

    /// Whether the file describes an animation, by flag or by carrying a frame table.
    public var isAnimated: Bool {
        flags.contains(.isGif) || (spriteSheet.map { !$0.frames.isEmpty } ?? false)
    }

    /// Mip level with the most pixels. Chosen by area rather than by index, because the
    /// file's level ordering is not something this reader assumes.
    public var largestMipmap: TextureMipmap? {
        mipmaps.max { ($0.width * $0.height) < ($1.width * $1.height) }
    }

    /// One image's mip chain.
    private static func readMipmaps(
        _ reader: inout BinaryReader,
        isEncodedImage: Bool,
        isVideo: Bool,
        warnings: inout [String]
    ) throws -> [TextureMipmap] {
        // 5 int32 fields is the smallest a mip record can be, before any payload.
        let mipmapCountField = try reader.readInt32()
        let mipmapCount = try reader.validatedCount(
            mipmapCountField,
            elementStride: 20,
            field: "mipmapCount"
        )
        var mipmaps: [TextureMipmap] = []
        mipmaps.reserveCapacity(min(mipmapCount, 64))

        for level in 0 ..< mipmapCount {
            let width = try Self.dimension(try reader.readInt32(), field: "mipmap \(level) width")
            let height = try Self.dimension(try reader.readInt32(), field: "mipmap \(level) height")
            let isCompressed = try reader.readInt32() != 0
            let uncompressedSizeField = try reader.readInt32()
            let compressedSizeField = try reader.readInt32()

            if isVideo {
                // The whole MP4, stored verbatim. Real files leave `uncompressedSize` at 0 and
                // give the file's length as `compressedSize`.
                let length = compressedSizeField > 0 ? compressedSizeField : uncompressedSizeField
                guard length > 0 else {
                    throw WEError.corruptField("mipmap \(level) is a video of 0 bytes")
                }
                mipmaps.append(
                    TextureMipmap(
                        width: width, height: height, wasCompressed: false,
                        isEncodedImage: false, data: try reader.readBytes(count: Int(length))
                    )
                )
                continue
            }

            // A FreeImage-encoded level carries a PNG or JPEG file rather than pixels, so
            // `uncompressedSize` does not apply and is stored as 0. `freeImageFormat` is -1
            // when the payload really is raw or LZ4-compressed pixels.
            guard isEncodedImage || uncompressedSizeField > 0 else {
                throw WEError.corruptField("mipmap \(level) declares uncompressedSize \(uncompressedSizeField)")
            }
            guard compressedSizeField >= 0 else {
                throw WEError.corruptField("mipmap \(level) declares compressedSize \(compressedSizeField)")
            }
            let uncompressedSize = Int(uncompressedSizeField)
            guard uncompressedSize <= reader.allocationLimit else {
                throw WEError.allocationTooLarge(uncompressedSize)
            }

            // The stored byte count is `compressedSize` for an LZ4 block and
            // `uncompressedSize` for a raw one — an uncompressed level leaves
            // `compressedSize` either zero or a copy of the uncompressed size.
            let payload: Data
            if isEncodedImage {
                // The whole file, verbatim. Decoding is the texture loader's job — it has
                // ImageIO and knows what pixel format the GPU wants.
                guard compressedSizeField > 0 else {
                    throw WEError.corruptField("mipmap \(level) is an encoded image of 0 bytes")
                }
                payload = try reader.readBytes(count: Int(compressedSizeField))
            } else if isCompressed {
                guard compressedSizeField > 0 else {
                    throw WEError.corruptField("mipmap \(level) is flagged compressed but is 0 bytes")
                }
                let block = try reader.readBytes(count: Int(compressedSizeField))
                payload = try Self.decodeLZ4(block, expectedSize: uncompressedSize)
            } else {
                payload = try reader.readBytes(count: uncompressedSize)
                if compressedSizeField != 0, Int(compressedSizeField) != uncompressedSize {
                    warnings.append(
                        "mipmap \(level) is uncompressed but declares compressedSize \(compressedSizeField)"
                    )
                }
            }

            mipmaps.append(
                TextureMipmap(
                    width: width, height: height, wasCompressed: isCompressed,
                    isEncodedImage: isEncodedImage, data: payload
                )
            )
        }
        return mipmaps
    }

    // MARK: - Sprite table

    /// Decodes the trailing `TEXS` table, if there is one.
    ///
    /// Layout, confirmed against all 18 animated textures in a real 59-scene library:
    ///
    /// ```text
    /// "TEXS000{1,2,3}"\0
    /// int32  frameCount
    /// [TEXS0003 only] int32 gifWidth, int32 gifHeight
    /// frame × frameCount {
    ///   int32 imageIndex
    ///   float duration                                  // seconds
    ///   x, y, width, widthY, heightX, height            // float; int32 in TEXS0001
    /// }
    /// ```
    ///
    /// The table has to fill the rest of the file exactly. Anything else yields a warning and no
    /// frames rather than a plausible-looking misparse.
    private static func parseSpriteSheet(_ reader: inout BinaryReader) -> (SpriteSheet?, [String]) {
        guard reader.remaining > 0 else { return (nil, []) }
        guard let peeked = reader.peekMagic(length: 4), peeked == "TEXS" else {
            return (nil, ["\(reader.remaining) trailing byte(s) after the last image are not a TEXS table"])
        }
        guard let version = try? reader.readNullTerminatedMagic(expectedLength: 8) else {
            return (nil, ["TEXS signature is truncated; frames ignored"])
        }
        guard supportedSpriteVersions.contains(version) else {
            return (nil, ["unsupported sprite table version \(version); frames ignored"])
        }

        let frameStride = 32
        var probe = reader
        guard let rawCount = try? probe.readInt32(), rawCount >= 0 else {
            return (nil, ["\(version) frame count is unreadable; frames ignored"])
        }
        var gifWidth: Int?
        var gifHeight: Int?
        if version == "TEXS0003" {
            guard let width = try? probe.readInt32(), let height = try? probe.readInt32() else {
                return (nil, ["\(version) header is truncated; frames ignored"])
            }
            gifWidth = Int(width)
            gifHeight = Int(height)
        }
        let frameCount = Int(rawCount)
        guard probe.remaining == frameCount * frameStride else {
            return (nil, [
                "\(version) declares \(frameCount) frame(s) but \(probe.remaining) byte(s) follow; frames ignored",
            ])
        }

        let integerRects = version == "TEXS0001"
        func component() throws -> Float {
            integerRects ? Float(try probe.readInt32()) : try probe.readFloat()
        }

        var frames: [SpriteFrame] = []
        frames.reserveCapacity(min(frameCount, 4096))
        do {
            for _ in 0 ..< frameCount {
                let imageIndex = Int(try probe.readInt32())
                let duration = try probe.readFloat()
                let x = try component(), y = try component(), width = try component()
                let widthY = try component(), heightX = try component(), height = try component()
                frames.append(
                    SpriteFrame(
                        imageIndex: imageIndex, duration: duration,
                        x: x, y: y, width: width, height: height,
                        widthY: widthY, heightX: heightX
                    )
                )
            }
        } catch {
            return (nil, ["\(version) table is truncated; frames ignored"])
        }

        reader = probe
        return (SpriteSheet(version: version, frames: frames, gifWidth: gifWidth, gifHeight: gifHeight), [])
    }

    // MARK: - Helpers

    /// LZ4 *raw block* decode via the system Compression framework — no third-party LZ4.
    ///
    /// `COMPRESSION_LZ4_RAW` is the frameless variant, which is what `.tex` stores; the
    /// framed `COMPRESSION_LZ4` would look for a magic this data does not have. The
    /// decoded length is checked against the mipmap's declared size, since
    /// `compression_decode_buffer` will happily stop early on a truncated block.
    static func decodeLZ4(_ source: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { throw WEError.corruptField("LZ4 target size \(expectedSize)") }
        guard expectedSize <= BinaryReader.maxReasonableAllocation else {
            throw WEError.allocationTooLarge(expectedSize)
        }
        guard !source.isEmpty else { throw WEError.decompressionFailed }

        var destination = Data(count: expectedSize)
        let written = destination.withUnsafeMutableBytes { rawDestination -> Int in
            source.withUnsafeBytes { rawSource -> Int in
                guard let out = rawDestination.bindMemory(to: UInt8.self).baseAddress,
                      let input = rawSource.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    out, expectedSize,
                    input, rawSource.count,
                    nil, COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written == expectedSize else { throw WEError.decompressionFailed }
        return destination
    }

    private static func dimension(_ value: Int32, field: String) throws -> Int {
        guard value > 0, value <= Int32(maxDimension) else {
            throw WEError.corruptField("\(field) is \(value)")
        }
        return Int(value)
    }

    private static func hasFourDigitSuffix(_ magic: String) -> Bool {
        magic.count == 8 && magic.dropFirst(4).allSatisfy(\.isNumber)
    }
}
