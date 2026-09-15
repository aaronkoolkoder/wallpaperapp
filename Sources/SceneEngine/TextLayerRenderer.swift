import AppKit
import CoreGraphics
import CoreText
import Diagnostics
import Foundation
import Metal
import WEFormat
import simd
import os

/// Rasterises a scene's text objects into textures.
///
/// Text is drawn once at load into a bitmap and uploaded as an ordinary texture, then composited
/// as a quad like any other layer. Rendering glyphs on the GPU every frame would mean a glyph
/// atlas and a text shader for content that, in a wallpaper, almost never changes — a clock is
/// the exception, and a clock re-rasterises once a minute rather than sixty times a second.
struct TextLayerRenderer {
    private let log = Logger(subsystem: "app.diorama", category: "text")

    /// Upper bound on the rasterised bitmap. Content can ask for an enormous point size, and a
    /// text object is untrusted input like everything else here.
    private static let maximumDimension = 4096

    struct Result {
        let texture: any MTLTexture
        /// Pixel dimensions, so the layer can size its quad to the text's real aspect.
        let size: SIMD2<Float>
    }

    /// Resolve the font a wallpaper asks for, falling back rather than failing.
    ///
    /// Workshop wallpapers name Windows fonts that are simply not present on a Mac. Substituting
    /// the system font keeps the layer readable and records the substitution, which is far more
    /// useful than an empty rectangle where a label should be.
    static func resolveFont(
        named name: String?, size: CGFloat, findings: inout [CompatibilityFinding]
    ) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: .medium)
        guard let name, !name.isEmpty else { return fallback }

        // WE font references sometimes carry an extension or a path.
        let cleaned = (name as NSString).deletingPathExtension
        if let font = NSFont(name: cleaned, size: size) { return font }

        findings.append(
            CompatibilityFinding(
                level: .degraded,
                feature: "Font",
                detail: "\(cleaned) is not installed; using the system font"
            )
        )
        return fallback
    }

    static func alignment(_ raw: String?) -> NSTextAlignment {
        switch raw?.lowercased() {
        case "right": .right
        case "center", "centre": .center
        default: .left
        }
    }

    func makeTexture(
        for object: SceneObject,
        device: any MTLDevice,
        findings: inout [CompatibilityFinding]
    ) -> Result? {
        guard let string = object.text, !string.isEmpty else { return nil }

        let pointSize = CGFloat(object.fontSize ?? 32)
        guard pointSize > 0 else { return nil }
        let font = Self.resolveFont(named: object.font, size: pointSize, findings: &findings)

        let colour = object.color ?? WEVector3(1, 1, 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = Self.alignment(object.horizontalAlign)

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor(
                srgbRed: CGFloat(colour.x), green: CGFloat(colour.y),
                blue: CGFloat(colour.z), alpha: 1
            ),
        ]

        // An outline is how text stays legible over arbitrary wallpaper artwork, so it is worth
        // honouring rather than dropping.
        if let outlineSize = object.outlineSize, outlineSize > 0 {
            let outline = object.outlineColor ?? WEVector3(0, 0, 0)
            attributes[.strokeWidth] = -abs(outlineSize)
            attributes[.strokeColor] = NSColor(
                srgbRed: CGFloat(outline.x), green: CGFloat(outline.y),
                blue: CGFloat(outline.z), alpha: 1
            )
        }

        let attributed = NSAttributedString(string: string, attributes: attributes)

        // Measure, then pad for the stroke and any glyph overhang, which `boundingRect` does not
        // fully account for and which otherwise clips descenders and outlines.
        let measured = attributed.boundingRect(
            with: CGSize(width: CGFloat(Self.maximumDimension), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let padding = max(4, (object.outlineSize.map { abs(CGFloat($0)) } ?? 0) * 2 + 4)
        let width = min(Self.maximumDimension, Int(measured.width.rounded(.up) + padding * 2))
        let height = min(Self.maximumDimension, Int(measured.height.rounded(.up) + padding * 2))
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        attributed.draw(
            with: CGRect(
                x: padding, y: padding,
                width: CGFloat(width) - padding * 2, height: CGFloat(height) - padding * 2
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let data = context.data else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "text:\(string.prefix(24))"
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4
        )

        return Result(texture: texture, size: SIMD2(Float(width), Float(height)))
    }
}
