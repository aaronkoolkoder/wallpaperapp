import Foundation
import Metal
import MetalRenderer
import ShaderTranspiler
import Testing
import WEFormat
@testable import SceneEngine

/// How a pass's `bind` entries reach its samplers.
///
/// Every fixture puts a flat red layer under a two-pass effect. The first pass writes flat
/// green into a named target; what the second pass shows depends entirely on which texture
/// each of its samplers ended up with — and an unbound one reads the renderer's white
/// placeholder, which is how these bugs looked on real wallpapers.
@Suite(
    "Effect bindings",
    .enabled(if: gpuAndToolchainAvailable, "needs a GPU and the vendored shader toolchain")
)
struct EffectBindingTests {

    private static let vertex = """
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    uniform mat4 g_ModelViewProjection;
    void main() {
        v_TexCoord = a_TexCoord;
        gl_Position = g_ModelViewProjection * vec4(a_Position, 1.0);
    }
    """

    private static let red = """
    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }
    """

    private static let green = """
    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }
    """

    private func makeWallpaper(
        finalShader: String, bind: String, fbos: String = "[]",
        effectVisible: String = "true", layerVisible: String = "true",
        placementPasses: String = "[]"
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaBind-\(UUID().uuidString)", isDirectory: true)
        for folder in ["shaders", "materials", "effects"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        for (name, fragment) in [("red", Self.red), ("green", Self.green), ("final", finalShader)] {
            let shaders = root.appendingPathComponent("shaders", isDirectory: true)
            try Self.vertex.write(
                to: shaders.appendingPathComponent("\(name).vert"), atomically: true, encoding: .utf8
            )
            try fragment.write(
                to: shaders.appendingPathComponent("\(name).frag"), atomically: true, encoding: .utf8
            )
            try #"{"passes":[{"blending":"normal","shader":"\#(name)","textures":["none"]}]}"#
                .write(
                    to: root.appendingPathComponent("materials/\(name).json"),
                    atomically: true, encoding: .utf8
                )
        }

        let effect = """
        {"name":"probe","fbos":\(fbos),"passes":[
          {"material":"materials/green.json","target":"_rt_stage"},
          {"material":"materials/final.json","bind":\(bind)}
        ]}
        """
        try effect.write(
            to: root.appendingPathComponent("effects/probe.json"), atomically: true, encoding: .utf8
        )

        let scene = """
        {
          "general": { "orthogonalprojection": { "width": 64, "height": 64 },
                       "clearcolor": "0 0 0" },
          "objects": [
            { "image": "materials/red.json", "name": "base", "origin": "32 32 0",
              "size": "64 64", "visible": \(layerVisible),
              "effects": [ { "file": "effects/probe.json", "visible": \(effectVisible),
                             "passes": \(placementPasses) } ] }
          ]
        }
        """
        try scene.write(
            to: root.appendingPathComponent("scene.json"), atomically: true, encoding: .utf8
        )
        return root
    }

    private func load(_ root: URL) throws -> (RenderableScene, SceneRenderer) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(renderDevice: try RenderDevice(device: device))
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "probe", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )
        renderer.setScene(scene)
        return (scene, renderer)
    }

    private func centre(_ renderer: SceneRenderer) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let image = try #require(renderer.renderOffscreen(width: 32, height: 32))
        let data = try #require(image.dataProvider?.data as Data?)
        let middle = (16 * image.bytesPerRow) + 16 * 4
        return (data[middle + 2], data[middle + 1], data[middle])
    }

    @Test("`previous` is the layer the effect is applied to, not a file")
    func previousIsTheChainInput() throws {
        // blur's final pass binds `previous` to blend the blur back over the original. Read
        // as a file it was always missing, the sampler got the white placeholder, and every
        // blurred layer came out white.
        let root = try makeWallpaper(
            finalShader: """
            varying vec2 v_TexCoord;
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture1;
            void main() { gl_FragColor = texture2D(g_Texture1, v_TexCoord); }
            """,
            bind: #"[{"index":0,"name":"_rt_stage"},{"index":1,"name":"previous"}]"#
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let (scene, renderer) = try load(root)
        #expect(!scene.report.findings.contains { $0.detail?.contains("previous") == true },
                "`previous` was looked up as a texture file")

        let pixel = try centre(renderer)
        #expect(pixel.r > 200 && pixel.g < 60 && pixel.b < 60,
                "expected the red layer, got \(pixel) — white means the placeholder was bound")
    }

    @Test("A binding reaches g_TextureN even when lower samplers are not declared")
    func bindIndexIsTheSamplerNumber() throws {
        // The shader declares only g_Texture2. By declaration order that is slot 0, so a
        // positional lookup finds nothing bound there and falls back to the layer (red); by
        // number it is index 2, which is bound to the green target.
        let root = try makeWallpaper(
            finalShader: """
            varying vec2 v_TexCoord;
            uniform sampler2D g_Texture2;
            void main() { gl_FragColor = texture2D(g_Texture2, v_TexCoord); }
            """,
            bind: #"[{"index":2,"name":"_rt_stage"}]"#
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let pixel = try centre(try load(root).1)
        #expect(pixel.g > 200 && pixel.r < 60 && pixel.b < 60,
                "expected the green target, got \(pixel)")
    }

    /// A final pass that shows the green target, so green means "the effect ran".
    private static let showStage = """
    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    void main() { gl_FragColor = texture2D(g_Texture0, v_TexCoord); }
    """

    @Test("An effect shipped switched off stays off until the user switches it on — live")
    func optionalEffectFollowsItsProperty() throws {
        let root = try makeWallpaper(
            finalShader: Self.showStage,
            bind: #"[{"index":0,"name":"_rt_stage"}]"#,
            effectVisible: #"{"user":"grain","value":false}"#
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, renderer) = try load(root)

        var pixel = try centre(renderer)
        #expect(pixel.r > 200 && pixel.g < 60, "the effect ran although it shipped off: \(pixel)")

        // No reload: the same renderer, with the setting changed underneath it.
        renderer.propertyOverrides = ["grain": .bool(true)]
        pixel = try centre(renderer)
        #expect(pixel.g > 200 && pixel.r < 60, "switching it on did nothing: \(pixel)")

        renderer.propertyOverrides = ["grain": .bool(false)]
        pixel = try centre(renderer)
        #expect(pixel.r > 200 && pixel.g < 60, "switching it off again did nothing: \(pixel)")
    }

    @Test("An effect tied to a list option runs only while that option is chosen")
    func listBoundEffect() throws {
        let root = try makeWallpaper(
            finalShader: Self.showStage,
            bind: #"[{"index":0,"name":"_rt_stage"}]"#,
            effectVisible: #"{"user":{"name":"style","condition":"2"},"value":false}"#
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, renderer) = try load(root)

        renderer.propertyOverrides = ["style": .number(2)]
        #expect(try centre(renderer).g > 200)
        renderer.propertyOverrides = ["style": .string("1")]
        #expect(try centre(renderer).r > 200)
    }

    @Test("A layer shipped hidden stays hidden until the user shows it")
    func optionalLayerFollowsItsProperty() throws {
        // The scene's clear colour is black, so a hidden layer leaves black behind it.
        let root = try makeWallpaper(
            finalShader: Self.showStage,
            bind: #"[{"index":0,"name":"_rt_stage"}]"#,
            layerVisible: #"{"user":"showBase","value":false}"#
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, renderer) = try load(root)

        var pixel = try centre(renderer)
        #expect(pixel.r < 30 && pixel.g < 30 && pixel.b < 30, "a hidden layer drew: \(pixel)")

        renderer.propertyOverrides = ["showBase": .bool(true)]
        pixel = try centre(renderer)
        #expect(pixel.g > 200, "showing the layer did nothing: \(pixel)")
    }

    /// A final pass whose colour comes only from its settings: `amount` sets the strength,
    /// and the TINT variant moves it from red to blue.
    private static let tunable = """
    // [COMBO] {"material":"tint","combo":"TINT","type":"options","default":0}
    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform float g_Amount; // {"material":"amount","label":"Amount","default":0}
    void main() {
    #if TINT == 1
        gl_FragColor = vec4(0.0, 0.0, g_Amount, 1.0);
    #else
        gl_FragColor = vec4(g_Amount, 0.0, 0.0, 1.0);
    #endif
    }
    """

    @Test("A placed effect runs with the author's tuned values, not the shader's defaults")
    func placementValuesApply() throws {
        // 350 of 360 placed effects in the test library carry tuned values; ignoring them ran
        // every one of them on its shader's defaults.
        let tuned = try makeWallpaper(
            finalShader: Self.tunable, bind: "[]",
            placementPasses: #"[{}, {"constantshadervalues":{"amount":1.0}}]"#
        )
        defer { try? FileManager.default.removeItem(at: tuned) }
        let pixel = try centre(try load(tuned).1)
        #expect(pixel.r > 200 && pixel.b < 60, "the placement's amount was not applied: \(pixel)")

        let defaults = try makeWallpaper(finalShader: Self.tunable, bind: "[]")
        defer { try? FileManager.default.removeItem(at: defaults) }
        let plain = try centre(try load(defaults).1)
        #expect(plain.r < 30, "with no placement settings the shader default of 0 applies: \(plain)")
    }

    @Test("A placed effect runs the variant the author picked")
    func placementCombosApply() throws {
        let root = try makeWallpaper(
            finalShader: Self.tunable, bind: "[]",
            placementPasses: #"[{}, {"combos":{"TINT":1},"constantshadervalues":{"amount":1.0}}]"#
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let pixel = try centre(try load(root).1)
        #expect(pixel.b > 200 && pixel.r < 60, "the placement's variant was not used: \(pixel)")
    }

    @Test("A declared framebuffer scale is kept with the compiled effect")
    func framebufferScalesAreKept() throws {
        let root = try makeWallpaper(
            finalShader: """
            varying vec2 v_TexCoord;
            uniform sampler2D g_Texture0;
            void main() { gl_FragColor = texture2D(g_Texture0, v_TexCoord); }
            """,
            bind: #"[{"index":0,"name":"_rt_stage"}]"#,
            fbos: #"[{"name":"_rt_stage","scale":4,"format":"rgba_backbuffer"}]"#
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let (scene, renderer) = try load(root)
        guard case .compiled(let effect) = try #require(scene.layers.first?.effects.first).implementation else {
            Issue.record("the probe effect did not compile")
            return
        }
        #expect(effect.targetScales["_rt_stage"] == 4)

        // A quarter-size target still has to carry the picture through.
        let pixel = try centre(renderer)
        #expect(pixel.g > 200 && pixel.r < 60)
    }
}

@Suite("Effect documents")
struct EffectDocumentFramebufferTests {

    @Test("Framebuffers decode with their scale")
    func decodesFramebuffers() throws {
        let json = #"""
        {"name":"blur","passes":[],"fbos":[
          {"name":"_rt_QuarterCompoBuffer1","scale":4,"format":"rgba_backbuffer"},
          {"name":"_rt_Half","scale":2.0},
          {"name":"_rt_Full"}
        ]}
        """#
        let document = try JSONDecoder().decode(EffectDocument.self, from: Data(json.utf8))
        #expect(document.framebuffers.map(\.scale) == [4, 2, 1])
        #expect(document.framebuffers.first?.format == "rgba_backbuffer")
    }

    @Test("Only `previous` names the chain's input")
    func previousIsRecognised() {
        #expect(EffectBinding(index: 2, name: "previous").isChainInput)
        #expect(!EffectBinding(index: 0, name: "_rt_QuarterCompoBuffer1").isChainInput)
        #expect(!EffectBinding(index: 1, name: "util/noise").isChainInput)
    }

    @Test("Sampler names give their texture index")
    func textureIndexParses() {
        #expect(EffectChainRunner.textureIndex(of: "g_Texture0") == 0)
        #expect(EffectChainRunner.textureIndex(of: "g_Texture12") == 12)
        #expect(EffectChainRunner.textureIndex(of: "g_Mask") == nil)
    }
}
