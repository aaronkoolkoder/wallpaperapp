import AppKit
import Diagnostics
import Foundation
import Metal
import Testing
import WEFormat
@testable import SceneEngine

@Suite("Text layers")
struct TextLayerTests {

    @Test("Falls back to the system font and says so")
    func missingFontFallsBack() {
        var findings: [CompatibilityFinding] = []
        // Workshop wallpapers name Windows fonts constantly. Failing the layer would leave an
        // empty rectangle where a label should be.
        let font = TextLayerRenderer.resolveFont(
            named: "Segoe UI Semibold", size: 32, findings: &findings
        )
        #expect(font.pointSize == 32)
        #expect(findings.contains { $0.feature == "Font" })
        #expect(findings.first?.detail?.contains("Segoe UI Semibold") == true)
    }

    @Test("An installed font resolves without a finding")
    func installedFontResolves() {
        var findings: [CompatibilityFinding] = []
        let font = TextLayerRenderer.resolveFont(named: "Helvetica", size: 24, findings: &findings)
        #expect(font.fontName.contains("Helvetica"))
        #expect(findings.isEmpty)
    }

    @Test("An absent font name is not reported as a failure")
    func noFontNameIsSilent() {
        var findings: [CompatibilityFinding] = []
        _ = TextLayerRenderer.resolveFont(named: nil, size: 20, findings: &findings)
        _ = TextLayerRenderer.resolveFont(named: "", size: 20, findings: &findings)
        // Declaring no font is normal, not a compatibility problem.
        #expect(findings.isEmpty)
    }

    @Test("Font references carrying an extension still resolve")
    func stripsFontExtension() {
        var findings: [CompatibilityFinding] = []
        let font = TextLayerRenderer.resolveFont(
            named: "Helvetica.ttf", size: 18, findings: &findings
        )
        #expect(font.fontName.contains("Helvetica"))
        #expect(findings.isEmpty)
    }

    @Test("Alignment maps from the format's spelling")
    func alignmentMapping() {
        #expect(TextLayerRenderer.alignment("center") == .center)
        #expect(TextLayerRenderer.alignment("centre") == .center)
        #expect(TextLayerRenderer.alignment("right") == .right)
        #expect(TextLayerRenderer.alignment("left") == .left)
        // An unrecognised value must still lay out.
        #expect(TextLayerRenderer.alignment("justified-ish") == .left)
        #expect(TextLayerRenderer.alignment(nil) == .left)
    }

    @Test("Rasterises text to a texture sized to the glyphs")
    func rasterises() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var findings: [CompatibilityFinding] = []

        let object = SceneObject(
            id: 1, name: "Label", kind: .text, text: "Hello", font: "Helvetica", fontSize: 48
        )
        let result = try #require(
            TextLayerRenderer().makeTexture(for: object, device: device, findings: &findings)
        )
        #expect(result.size.x > 0 && result.size.y > 0)
        #expect(result.texture.width == Int(result.size.x))
    }

    @Test("Empty text produces nothing rather than a blank texture")
    func emptyTextSkipped() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var findings: [CompatibilityFinding] = []

        for text in ["", nil] as [String?] {
            let object = SceneObject(id: 1, kind: .text, text: text, fontSize: 32)
            #expect(
                TextLayerRenderer().makeTexture(
                    for: object, device: device, findings: &findings
                ) == nil
            )
        }
    }

    @Test("A non-positive font size is rejected rather than trapping")
    func rejectsBadFontSize() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var findings: [CompatibilityFinding] = []

        for size in [0.0, -12.0] {
            let object = SceneObject(id: 1, kind: .text, text: "x", fontSize: size)
            #expect(
                TextLayerRenderer().makeTexture(
                    for: object, device: device, findings: &findings
                ) == nil
            )
        }
    }

    @Test("Text is drawn at four pixels per point, the size Wallpaper Engine lays it out at")
    func pointSizeScale() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var findings: [CompatibilityFinding] = []
        // Real content: a 5pt label whose saved text box is 20 units tall.
        let object = SceneObject(id: 1, kind: .text, text: "Label", font: "Helvetica", fontSize: 5)
        let result = try #require(
            TextLayerRenderer().makeTexture(for: object, device: device, findings: &findings)
        )
        #expect(result.size.y >= 20 && result.size.y <= 40, "got \(result.size)")
    }

    @Test("Wallpaper Engine's Windows font names resolve to Mac fonts")
    func systemFonts() {
        var findings: [CompatibilityFinding] = []
        let arial = TextLayerRenderer.resolveFont(named: "systemfont_arial", size: 20, findings: &findings)
        #expect(arial.familyName == "Arial")
        #expect(findings.isEmpty)

        let consolas = TextLayerRenderer.resolveFont(named: "systemfont_consolas", size: 20, findings: &findings)
        #expect(consolas.isFixedPitch)
        #expect(findings.contains { $0.feature == "Font" })
    }

    @Test("A scripted text layer is built showing its script's text, and stays bound to it")
    func scriptedTextLayer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let document = try JSONDecoder().decode(SceneDocument.self, from: Data(#"""
        {"objects": [{"id": 1, "name": "Clock", "pointsize": 8, "font": "systemfont_arial",
          "text": {"script": "export var p = createScriptProperties().addText({name: 'word', value: 'no'}).finish();\nexport function update(value) { return p.word + '!'; }",
                   "scriptproperties": {"word": "hi"}, "value": "12:34"}}]}
        """#.utf8))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-text-\(UUID())")
        let scene = SceneBuilder().build(
            document: document,
            assets: SceneAssets(wallpaperID: "text", directory: root, packageURL: nil),
            device: device
        )
        let layer = try #require(scene.layers.first)
        #expect(layer.texture?.label == "text:hi!")
        #expect(scene.textBindings.map(\.layerIndex) == [0])
        #expect(scene.textBindings.first?.text == "hi!")
    }

    @Test("An absurd font size is clamped rather than allocating unboundedly")
    func clampsAbsurdSize() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var findings: [CompatibilityFinding] = []

        // Untrusted content: a text object can ask for any point size at all.
        let object = SceneObject(id: 1, kind: .text, text: "Wide", fontSize: 40_000)
        if let result = TextLayerRenderer().makeTexture(
            for: object, device: device, findings: &findings
        ) {
            #expect(result.texture.width <= 4096)
            #expect(result.texture.height <= 4096)
        }
    }
}
