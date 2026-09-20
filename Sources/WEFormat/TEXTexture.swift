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
/// - Important: Only the first two fields are confirmed. See ``quadComponents``.
public struct SpriteFrame: Sendable, Hashable {

    /// Index of the image this frame samples from.
    public let imageIndex: Int32

    /// Frame duration. Wallpaper Engine stores GIF timings in milliseconds.
    public let durationMilliseconds: Float

    /// Every float stored after the duration, verbatim and in file order.
    ///
    /// - TODO: The exact meaning of these floats is **not confirmed**. `TEXS` frames are
    ///   known to carry a source-rectangle quad, and the number of floats varies between
    ///   table revisions — four in the simple case, six in the variant that also encodes
    ///   a rotated source rect. Which slot holds width versus height in the six-float
    ///   form could not be determined without a reference file, so this reader stores the
    ///   floats untouched and ``width``/``height`` deliberately return `nil` there rather
    ///   than guess. Confirm against a real animated `.tex` before the renderer relies on
    ///   a specific slot.
    public let quadComponents: [Float]

    public init(imageIndex: Int32, durationMilliseconds: Float, quadComponents: [Float]) {
        self.imageIndex = imageIndex
        self.durationMilliseconds = durationMilliseconds
        self.quadComponents = quadComponents
    }

    /// First quad component. Believed to be the source-rect origin X; see ``quadComponents``.
    public var x: Float? { quadComponents.count >= 2 ? quadComponents[0] : nil }

    /// Second quad component. Believed to be the source-rect origin Y; see ``quadComponents``.
    public var y: Float? { quadComponents.count >= 2 ? quadComponents[1] : nil }

    /// Source-rect width — only exposed for four-component frames, where the layout is
    /// unambiguous. `nil` for the rotated six-component variant.
    public var width: Float? { quadComponents.count == 4 ? quadComponents[2] : nil }

    /// Source-rect height — see ``width``.
    public var height: Float? { quadComponents.count == 4 ? quadComponents[3] : nil }
}

/// The optional animation frame table that follows the mipmaps in an animated `.tex`.
public struct SpriteSheet: Sendable, Hashable {
    /// Signature as it appeared in the file, e.g. `"TEXS0003"`.
    public let version: String
    public let frames: [SpriteFrame]
    /// Floats per frame after the image index and duration — the stride this reader
    /// inferred from the table's own size. See ``SpriteFrame/quadComponents``.
    public let componentsPerFrame: Int

    public init(version: String, frames: [SpriteFrame], componentsPerFrame: Int) {
        self.version = version
        self.frames = frames
        self.componentsPerFrame = componentsPerFrame
    }
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
/// "TEXB000{1,2,3}"\0           // mipmap container version
///   [TEXB0003 only] int32 _unknown
///   [TEXB0003 only] int32 freeImageFormat
/// int32  mipmapCount
/// mip × mipmapCount { width, height, isCompressed, uncompressedSize, compressedSize, data }
/// [optional] "TEXS000{1,2,3}"  // animated sprite frame table
/// ```
///
/// Anything the reader could not make sense of but survived — an unrecognised pixel
/// format, an unparseable sprite table, trailing bytes — lands in ``warnings`` instead of
/// failing the parse, so a partially-understood texture still reports what it does know
/// to the compatibility report.
public struct TEXTexture: Sendable {

    /// Revisions of the mipmap container this reader decodes.
    public static let supportedContainerVersions = ["TEXB0001", "TEXB0002", "TEXB0003"]

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

    /// Mip levels in file order, payloads already decompressed.
    public let mipmaps: [TextureMipmap]

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
            throw WEError.badMagic(expected: "TEXB0001…TEXB0003", found: containerVersion)
        }

        // Every revision carries one undocumented int32 ahead of the mipmap count; TEXB0003
        // adds a second field naming the FreeImage source format. Dispatching here keeps the
        // difference in one place if a fourth revision appears.
        //
        // Getting this wrong is silent and total: skipping the leading field on TEXB0001/0002
        // makes the parser read it *as* the mipmap count, so every older texture decodes to
        // garbage rather than failing loudly.
        _ = try reader.readInt32()                        // undocumented, all revisions
        var freeImageFormat: Int32?
        if containerVersion == "TEXB0003" {
            freeImageFormat = try reader.readInt32()
        }

        // --- Mipmaps ---------------------------------------------------------------
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

            // A FreeImage-encoded level carries a PNG or JPEG file rather than pixels, so
            // `uncompressedSize` does not apply and is stored as 0. `freeImageFormat` is -1
            // when the payload really is raw or LZ4-compressed pixels.
            let isEncodedImage = (freeImageFormat ?? -1) >= 0

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

    // MARK: - Sprite table

    /// Decodes the trailing `TEXS` table, if there is one.
    ///
    /// The table's per-frame stride is **inferred from the table's own size** rather than
    /// hard-coded: `frameCount` frames must exactly fill the remaining bytes, and the
    /// leftover per frame — after the `int32` image index and `float` duration — must be
    /// a whole number of floats. Two candidate preambles are tried, since some revisions
    /// are reported to precede `frameCount` with a pair of `int32` dimensions.
    ///
    /// This is deliberately conservative: an inconsistent table yields a warning and no
    /// frames rather than a plausible-looking misparse. See ``SpriteFrame/quadComponents``.
    private static func parseSpriteSheet(_ reader: inout BinaryReader) -> (SpriteSheet?, [String]) {
        guard reader.remaining > 0 else { return (nil, []) }
        guard let peeked = reader.peekMagic(length: 4), peeked == "TEXS" else {
            return (nil, ["\(reader.remaining) trailing byte(s) after the last mipmap are not a TEXS table"])
        }

        var warnings: [String] = []
        guard let spriteVersion = try? reader.readNullTerminatedMagic(expectedLength: 8) else {
            return (nil, ["TEXS signature is truncated; frames ignored"])
        }
        guard supportedSpriteVersions.contains(spriteVersion) else {
            return (nil, ["unsupported sprite table version \(spriteVersion); frames ignored"])
        }

        let tableStart = reader.offset
        for preambleInt32s in [0, 2] {
            var probe = reader
            guard (try? probe.seek(to: tableStart)) != nil,
                  (try? probe.skip(preambleInt32s * 4)) != nil,
                  let rawFrameCount = try? probe.readInt32(),
                  rawFrameCount >= 0
            else { continue }

            let frameCount = Int(rawFrameCount)
            let body = probe.remaining

            if frameCount == 0 {
                guard body == 0 else { continue }
                reader = probe
                return (SpriteSheet(version: spriteVersion, frames: [], componentsPerFrame: 0), warnings)
            }

            // A frame is at least an int32 index plus a float duration.
            guard frameCount <= body / 8, body % frameCount == 0 else { continue }
            let stride = body / frameCount
            guard stride > 8, (stride - 8) % 4 == 0 else { continue }
            let componentsPerFrame = (stride - 8) / 4
            guard (2 ... 8).contains(componentsPerFrame) else { continue }

            var frames: [SpriteFrame] = []
            frames.reserveCapacity(min(frameCount, 4096))
            var complete = true

            frameLoop: for _ in 0 ..< frameCount {
                guard let imageIndex = try? probe.readInt32(),
                      let duration = try? probe.readFloat()
                else { complete = false; break }

                var components: [Float] = []
                components.reserveCapacity(componentsPerFrame)
                for _ in 0 ..< componentsPerFrame {
                    guard let value = try? probe.readFloat() else { complete = false; break frameLoop }
                    components.append(value)
                }
                frames.append(
                    SpriteFrame(
                        imageIndex: imageIndex,
                        durationMilliseconds: duration,
                        quadComponents: components
                    )
                )
            }

            guard complete else { continue }
            if preambleInt32s != 0 {
                warnings.append(
                    "\(spriteVersion) frame count followed a \(preambleInt32s * 4)-byte preamble"
                )
            }
            reader = probe
            return (
                SpriteSheet(
                    version: spriteVersion,
                    frames: frames,
                    componentsPerFrame: componentsPerFrame
                ),
                warnings
            )
        }

        warnings.append(
            "could not determine \(spriteVersion) frame layout from \(reader.remaining) trailing byte(s); frames ignored"
        )
        return (nil, warnings)
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
