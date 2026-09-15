import Foundation
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

        public var errorDescription: String? {
            switch self {
            case .noMipmaps: "The texture contains no image data"
            case .unsupportedFormat(let raw): "Unsupported texture format \(raw)"
            case .blockCompressionUnavailable(let name):
                "This GPU cannot use \(name) textures"
            case .allocationFailed: "Could not allocate the texture"
            }
        }
    }

    /// Map a Wallpaper Engine pixel format onto Metal's.
    ///
    /// Note the ARGB8888 case: the name is the *channel order Wallpaper Engine uses in its own
    /// naming*, but the bytes on disk are BGRA, which is what `.bgra8Unorm` expects. Treating the
    /// name literally and picking `.rgba8Unorm` swaps red and blue on every uncompressed texture
    /// — a subtle, entirely plausible-looking failure.
    static func pixelFormat(for format: TextureFormat) -> MTLPixelFormat? {
        switch format {
        case .argb8888: .bgra8Unorm
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

    public func makeTexture(
        from texture: TEXTexture,
        device: any MTLDevice,
        label: String? = nil
    ) throws -> any MTLTexture {
        guard let base = texture.mipmaps.first else { throw LoadError.noMipmaps }
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
