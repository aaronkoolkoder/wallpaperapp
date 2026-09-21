import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Metal
import WEFormat
import os

/// Uploads Wallpaper Engine `.tex` textures to Metal.
///
/// Block-compressed textures are uploaded **as-is**, with no transcode. Apple Silicon supports
/// BC natively (`supportsBCTextureCompression`), so DXT1/3/5 go straight to the GPU and stay
/// compressed in VRAM — which matters a great deal for a process that is resident all day with a
/// scene's worth of textures loaded. A CPU decode path exists only for hardware that reports no
/// BC support.
public struct TextureLoader: Sendable {
    private let log = Logger(subsystem: "app.diorama", category: "texture")

    public init() {}

    public enum LoadError: Error, LocalizedError {
        case noMipmaps
        case unsupportedFormat(Int32)
        case blockCompressionUnavailable(String)
        case allocationFailed
        /// A PNG or JPEG mipmap that ImageIO would not decode.
        case undecodableImage(String)

        public var errorDescription: String? {
            switch self {
            case .undecodableImage(let name): "\(name) holds an image macOS could not decode"
            case .noMipmaps: "The texture contains no image data"
            case .unsupportedFormat(let raw): "Unsupported texture format \(raw)"
            case .blockCompressionUnavailable(let name):
                "This GPU cannot use \(name) textures"
            case .allocationFailed: "Could not allocate the texture"
            }
        }
    }

    /// Converts premultiplied BGRA8 pixels to straight alpha, in place.
    static func unpremultiply(_ pixels: inout [UInt8], width: Int, height: Int, bytesPerRow: Int) {
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var buffer = vImage_Buffer(
                data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: bytesPerRow
            )
            // The RGBA variant, which is the same operation for BGRA: it divides the first
            // three channels by the fourth, whatever order those three are in.
            _ = vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        }
    }

    /// Map a Wallpaper Engine pixel format onto Metal's.
    ///
    /// Format 0 — what this code base calls `argb8888` — holds its bytes in **R, G, B, A**
    /// order. This used to say BGRA, as an assertion with nothing behind it, and every raw
    /// texture had its red and blue swapped: Sonic's Green Hill Zone rendered under a red sky
    /// over orange water. Three independent checks settle it:
    ///
    /// - Colour: that sky's texture averages 42 in byte 0 and 175 in byte 2, and the sky is
    ///   blue. A skin-tone texture averages 215 in byte 0 and 149 in byte 2.
    /// - Flow maps: shake's direction masks carry their direction in bytes 0 and 1 and leave
    ///   byte 2 exactly zero — a 2D flow map's R and G, with B unused. Read as BGRA, the x
    ///   direction came from the empty channel, (0 - 0.498) * 2 = -1, and every shaken layer
    ///   was dragged left at full strength, smearing its edge.
    /// - repkg, which reads this format as RGBA8888 and loads it straight into RGBA pixels.
    static func pixelFormat(for format: TextureFormat) -> MTLPixelFormat? {
        switch format {
        case .argb8888: .rgba8Unorm
        case .dxt1: .bc1_rgba
        case .dxt3: .bc2_rgba
        case .dxt5: .bc3_rgba
        case .rg88: .rg8Unorm
        case .r8: .r8Unorm
        }
    }

    /// Bytes per row for one mip level.
    ///
    /// Block-compressed formats address a 4x4 block at a time, so the row stride is measured in
    /// blocks, not pixels — and the block count rounds *up*, which is why a 5-pixel-wide mip
    /// still occupies two blocks.
    static func bytesPerRow(format: TextureFormat, width: Int) -> Int {
        switch format {
        case .dxt1:
            max(1, (width + 3) / 4) * 8
        case .dxt3, .dxt5:
            max(1, (width + 3) / 4) * 16
        case .argb8888:
            width * 4
        case .rg88:
            width * 2
        case .r8:
            width
        }
    }

    /// Decodes a PNG or JPEG mipmap and uploads it.
    ///
    /// Only the base level: the encoded levels are separate files and decoding all of them costs
    /// more than letting Metal generate the chain, which it does from the base.
    private func makeTextureFromEncodedImage(
        _ mip: TextureMipmap,
        device: any MTLDevice,
        label: String?
    ) throws -> any MTLTexture {
        guard let source = CGImageSourceCreateWithData(mip.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw LoadError.undecodableImage(label ?? "texture")
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw LoadError.undecodableImage(label ?? "texture")
        }

        // Drawn into a known layout rather than trusting whatever the file happened to use:
        // PNGs arrive as palettised, 16-bit, greyscale and every other shape ImageIO supports,
        // and Metal wants one of them.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colourSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colourSpace, bitmapInfo: info
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw LoadError.undecodableImage(label ?? "texture") }

        // Back to straight alpha. CoreGraphics only draws 8-bit RGBA premultiplied, but a PNG
        // holds straight alpha, and so does every other texture this renderer uploads: the
        // built-in shader premultiplies after sampling, and a wallpaper's own shaders blend as
        // straight alpha. Left premultiplied, every soft edge was multiplied by its alpha twice
        // — a half-transparent pixel came out at a quarter of its colour, a dark fringe
        // around anything anti-aliased.
        Self.unpremultiply(&pixels, width: width, height: height, bytesPerRow: bytesPerRow)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed

        guard let metalTexture = device.makeTexture(descriptor: descriptor) else {
            throw LoadError.allocationFailed
        }
        metalTexture.label = label
        pixels.withUnsafeBytes { raw in
            metalTexture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return metalTexture
    }

    public func makeTexture(
        from texture: TEXTexture,
        device: any MTLDevice,
        label: String? = nil
    ) throws -> any MTLTexture {
        guard let base = texture.mipmaps.first else { throw LoadError.noMipmaps }

        // A FreeImage-encoded texture holds a PNG or JPEG per level rather than pixels, and its
        // declared `format` describes what the pixels *will* be once decoded, not what is
        // stored. ImageIO does the decoding; the rest of this function would read the file
        // bytes as though they were a pixel buffer.
        if base.isEncodedImage {
            return try makeTextureFromEncodedImage(base, device: device, label: label)
        }

        guard let format = texture.format else {
            throw LoadError.unsupportedFormat(texture.rawFormat)
        }
        guard let pixelFormat = Self.pixelFormat(for: format) else {
            throw LoadError.unsupportedFormat(texture.rawFormat)
        }

        if format.isBlockCompressed, !device.supportsBCTextureCompression {
            // No silent fallback: a wrong-looking texture is worse than an honest report, and
            // every Mac this app targets supports BC.
            throw LoadError.blockCompressionUnavailable(String(describing: format))
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: base.width,
            height: base.height,
            mipmapped: texture.mipmaps.count > 1
        )
        descriptor.usage = .shaderRead
        descriptor.mipmapLevelCount = texture.mipmaps.count
        // Managed rather than private: the data arrives on the CPU and is written once with
        // `replace`. A private texture would need a staging buffer and a blit for no benefit on
        // a unified-memory machine.
        descriptor.storageMode = .managed

        guard let metalTexture = device.makeTexture(descriptor: descriptor) else {
            throw LoadError.allocationFailed
        }
        metalTexture.label = label

        for (level, mip) in texture.mipmaps.enumerated() {
            let region = MTLRegionMake2D(0, 0, mip.width, mip.height)
            let stride = Self.bytesPerRow(format: format, width: mip.width)

            // Guard against a mip whose declared size does not match its payload. This is
            // untrusted content, and `replace` reads exactly as many bytes as the region and
            // stride imply — a short buffer is an out-of-bounds read, not an error.
            let rows = format.isBlockCompressed ? max(1, (mip.height + 3) / 4) : mip.height
            let required = stride * rows
            guard mip.data.count >= required else {
                log.warning(
                    "mip \(level) of \(label ?? "texture", privacy: .public) has \(mip.data.count) bytes, needs \(required); skipping"
                )
                continue
            }

            mip.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                metalTexture.replace(
                    region: region, mipmapLevel: level, withBytes: base, bytesPerRow: stride
                )
            }
        }

        return metalTexture
    }
}
