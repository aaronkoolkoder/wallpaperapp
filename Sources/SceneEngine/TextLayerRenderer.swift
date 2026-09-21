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

    /// Pixels per point of a text object's `pointsize`.
    ///
    /// Not documented anywhere; measured. Every text object Wallpaper Engine saves records the
    /// box its text occupies, and across all 38 in a real library that box is the text set at
    /// four pixels per point — a 5pt monospaced label 11 characters long is 132x20, a 32pt
    /// "12:34" about 330x155, a 96pt one 1057x544 — whatever the scene's resolution. Drawn at
    /// one pixel per point, text came out a quarter of the size it was authored at.
    static let pixelsPerPoint: CGFloat = 4

    struct Result {
        let texture: any MTLTexture
        /// Pixel dimensions, so the layer can size its quad to the text's real aspect.
        let size: SIMD2<Float>
    }

    /// Everything about a text object except the string, resolved once so a clock can redraw
    /// every minute without looking its font up again.
    struct Style: @unchecked Sendable {
        let font: NSFont
        let colour: NSColor
        let alignment: NSTextAlignment
        let outlineSize: CGFloat
        let outlineColour: NSColor
        /// Width of the box the editor saved around the text. Alignment is within this box —
        /// 23 of the 38 text objects in a real library are left-aligned in a box wider than
        /// their text, and centring the text instead pushed each line into its neighbour.
        let boxWidth: CGFloat
    }

    /// Wallpaper Engine's names for the Windows fonts it lets authors pick without shipping
    /// them, mapped to what a Mac has. `nil` means the system font.
    static func systemFontSubstitute(for name: String) -> String? {
        switch name.lowercased() {
        case "arial": "Arial"
        case "arialblack": "Arial Black"
        case "timesnewroman": "Times New Roman"
        case "couriernew": "Courier New"
        case "verdana": "Verdana"
        case "tahoma": "Tahoma"
        case "trebuchetms", "trebuchet": "Trebuchet MS"
        case "georgia": "Georgia"
        case "impact": "Impact"
        case "comicsansms", "comicsans": "Comic Sans MS"
        default: nil
        }
    }

    /// Resolve the font a wallpaper asks for, falling back rather than failing.
    ///
    /// In order: a font file shipped inside the wallpaper, which is how most text in a real
    /// library names its font (`fonts/VCR_OSD_MONO_1.001.ttf`); one of Wallpaper Engine's
    /// `systemfont_` names; an installed font by name; and finally the system font, with the
    /// substitution recorded — far more useful than an empty rectangle where a label should be.
    static func resolveFont(
        named name: String?, size: CGFloat, assets: SceneAssets? = nil,
        findings: inout [CompatibilityFinding]
    ) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: .medium)
        guard let name, !name.isEmpty else { return fallback }
        let normalized = name.replacingOccurrences(of: "\\", with: "/")

        if let data = assets?.data(for: normalized),
           let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData)
               as? [CTFontDescriptor],
           let descriptor = descriptors.first {
            return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
        }

        if normalized.lowercased().hasPrefix("systemfont_") {
            let wanted = String(normalized.dropFirst("systemfont_".count))
            if let family = systemFontSubstitute(for: wanted),
               let font = NSFont(name: family, size: size) {
                return font
            }
            let monospaced = ["consolas", "lucidaconsole", "couriernew"].contains(wanted.lowercased())
            findings.append(
                CompatibilityFinding(
                    level: .degraded, feature: "Font",
                    detail: "\(wanted) is a Windows font; using "
                        + (monospaced ? "the system monospaced font" : "the system font")
                )
            )
            return monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : fallback
        }

        // WE font references sometimes carry an extension or a path.
        let cleaned = ((normalized as NSString).lastPathComponent as NSString).deletingPathExtension
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

    func style(
        for object: SceneObject, assets: SceneAssets?, findings: inout [CompatibilityFinding]
    ) -> Style? {
        let pointSize = CGFloat(object.fontSize ?? 32) * Self.pixelsPerPoint
        guard pointSize > 0, pointSize.isFinite else { return nil }
        let colour = object.color ?? WEVector3(1, 1, 1)
        let outline = object.outlineColor ?? WEVector3(0, 0, 0)
        return Style(
            font: Self.resolveFont(
                named: object.font, size: min(pointSize, CGFloat(Self.maximumDimension)),
                assets: assets, findings: &findings
            ),
            colour: NSColor(
                srgbRed: CGFloat(colour.x), green: CGFloat(colour.y),
                blue: CGFloat(colour.z), alpha: 1
            ),
            alignment: Self.alignment(object.horizontalAlign),
            outlineSize: CGFloat(max(0, object.outlineSize ?? 0)),
            outlineColour: NSColor(
                srgbRed: CGFloat(outline.x), green: CGFloat(outline.y),
                blue: CGFloat(outline.z), alpha: 1
            ),
            boxWidth: min(CGFloat(max(0, object.size?.x ?? 0)), CGFloat(Self.maximumDimension))
        )
    }

    func makeTexture(
        for object: SceneObject,
        assets: SceneAssets? = nil,
        device: any MTLDevice,
        findings: inout [CompatibilityFinding]
    ) -> Result? {
        guard let string = object.text, !string.isEmpty,
              let style = style(for: object, assets: assets, findings: &findings)
        else { return nil }
        return makeTexture(text: string, style: style, device: device)
    }

    func makeTexture(text string: String, style: Style, device: any MTLDevice) -> Result? {
        guard !string.isEmpty else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment

        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .paragraphStyle: paragraph,
            .foregroundColor: style.colour,
        ]

        // An outline is how text stays legible over arbitrary wallpaper artwork, so it is worth
        // honouring rather than dropping.
        if style.outlineSize > 0 {
            attributes[.strokeWidth] = -style.outlineSize
            attributes[.strokeColor] = style.outlineColour
        }

        let attributed = NSAttributedString(string: string, attributes: attributes)

        // Measure, then pad for the stroke and any glyph overhang, which `boundingRect` does not
        // fully account for and which otherwise clips descenders and outlines.
        let measured = attributed.boundingRect(
            with: CGSize(width: CGFloat(Self.maximumDimension), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let padding = max(4, style.outlineSize * 2 + 4)
        let textWidth = max(measured.width.rounded(.up), style.boxWidth)
        let width = min(Self.maximumDimension, Int(textWidth + padding * 2))
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
