import CoreGraphics
import Foundation
import Metal
import MetalRenderer
import ShaderTranspiler
import Testing
import WEFormat
@testable import SceneEngine


/// Renders a wallpaper whose effect has its own shaders, and checks the author's passes ran
/// rather than a built-in approximation of them.
@Suite(
    "Effect chain",
    .enabled(if: gpuAndToolchainAvailable, "needs a GPU and the vendored shader toolchain")
)
struct EffectChainTests {

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

    /// The layer under the effect: flat red.
    private static let layerFragment = """
    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }
    """

    /// The effect: swaps red into blue. No built-in approximation does this, so seeing blue
    /// means the author's pass ran and read the layer beneath it.
    private static let effectFragment = """
    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    void main() {
        vec4 source = texture2D(g_Texture0, v_TexCoord);
        gl_FragColor = vec4(source.g, source.b, source.r, source.a);
    }
    """

    /// A second pass, to prove a chain runs in order: swaps again, so red goes to blue then
    /// to green. Only running both passes gives green.
    private static let secondPassFragment = """
    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    void main() {
        vec4 source = texture2D(g_Texture0, v_TexCoord);
        gl_FragColor = vec4(source.g, source.b, source.r, source.a);
    }
    """

    private func makeWallpaper(passes: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaEffect-\(UUID().uuidString)", isDirectory: true)
        for folder in ["shaders", "materials", "effects"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        func writeShader(_ name: String, fragment: String) throws {
            let shaders = root.appendingPathComponent("shaders", isDirectory: true)
            try Self.vertex.write(
                to: shaders.appendingPathComponent("\(name).vert"), atomically: true, encoding: .utf8
            )
            try fragment.write(
                to: shaders.appendingPathComponent("\(name).frag"), atomically: true, encoding: .utf8
            )
        }
        try writeShader("layer", fragment: Self.layerFragment)
        try writeShader("swap", fragment: Self.effectFragment)
        try writeShader("swap2", fragment: Self.secondPassFragment)

        func writeMaterial(_ name: String, shader: String) throws {
            try #"{"passes":[{"blending":"normal","shader":"\#(shader)","textures":["none"]}]}"#
                .write(
                    to: root.appendingPathComponent("materials/\(name).json"),
                    atomically: true, encoding: .utf8
                )
        }
        try writeMaterial("layer", shader: "layer")
        try writeMaterial("swap", shader: "swap")
        try writeMaterial("swap2", shader: "swap2")

        // A two-pass chain writes its first result to a named target the second reads.
        let effectPasses = passes == 1
            ? #"[{"material":"materials/swap.json"}]"#
            : #"""
              [{"material":"materials/swap.json","target":"_rt_stage"},
               {"material":"materials/swap2.json","bind":[{"index":0,"name":"_rt_stage"}]}]
              """#
        try #"{"name":"swap","passes":\#(effectPasses)}"#.write(
            to: root.appendingPathComponent("effects/swap.json"), atomically: true, encoding: .utf8
        )

        let scene = """
        {
          "general": { "orthogonalprojection": { "width": 64, "height": 64 },
                       "clearcolor": "0 0 0" },
          "objects": [
            { "image": "materials/layer.json", "name": "base", "origin": "32 32 0",
              "size": "64 64", "visible": true,
              "effects": [ { "file": "effects/swap.json", "visible": true } ] }
          ]
        }
        """
        try scene.write(
            to: root.appendingPathComponent("scene.json"), atomically: true, encoding: .utf8
        )
        return root
    }

    private func centrePixel(root: URL) throws -> (r: UInt8, g: UInt8, b: UInt8)? {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(renderDevice: try RenderDevice(device: device))
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "swap", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )
        renderer.setScene(scene)

        guard let image = renderer.renderOffscreen(width: 32, height: 32),
              let data = image.dataProvider?.data as Data?
        else { return nil }
        let middle = (16 * image.bytesPerRow) + 16 * 4
        guard middle + 3 < data.count else { return nil }
        return (data[middle + 2], data[middle + 1], data[middle])
    }

    @Test("A single-pass effect runs its own shader over the layer beneath it")
    func runsSinglePass() throws {
        // Red in, blue out. No approximation in PostProcessor rotates channels, so blue can
        // only come from the author's pass having run and sampled the layer.
        let root = try makeWallpaper(passes: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        let pixel = try #require(try centrePixel(root: root))
        #expect(pixel.b > 200)
        #expect(pixel.r < 60)
        #expect(pixel.g < 60)
    }

    @Test("A layer's effect output covers the whole frame, not one corner of it")
    func effectedLayerCoversTheFrame() throws {
        // Samples all four quadrants, not only the centre: a composite placed a half-frame off
        // still passes through the middle pixel. This goes through the same composition the
        // desktop uses — the harness once had its own, which never ran the per-layer path.
        let root = try makeWallpaper(passes: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(renderDevice: try RenderDevice(device: device))
        renderer.setScene(try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "swap", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        ))
        // Not a size the pool's buckets fit exactly, which is what the desktop always is.
        let image = try #require(renderer.renderOffscreen(width: 50, height: 30))
        let data = try #require(image.dataProvider?.data as Data?)

        for (x, y) in [(8, 6), (41, 6), (8, 23), (41, 23)] {
            let offset = y * image.bytesPerRow + x * 4
            let (b, g, r, a) = (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
            #expect(b > 200 && r < 60 && g < 60 && a > 200,
                    "(\(x),\(y)) is r=\(r) g=\(g) b=\(b) a=\(a), not the effect's blue")
        }
    }

    @Test("A two-pass chain runs both passes, in order")
    func runsChainInOrder() throws {
        // Red, then blue, then green. Getting blue would mean the second pass never ran;
        // getting red would mean neither did.
        let root = try makeWallpaper(passes: 2)
        defer { try? FileManager.default.removeItem(at: root) }

        let pixel = try #require(try centrePixel(root: root))
        #expect(pixel.g > 200)
        #expect(pixel.r < 60)
        #expect(pixel.b < 60)
    }

    @Test("A compiled effect is reported as compiled, not as approximated")
    func reportsCompiled() throws {
        let root = try makeWallpaper(passes: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "swap", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )
        #expect(scene.layers.first?.effects.first?.isCompiled == true)
        #expect(!scene.report.findings.contains { $0.detail?.contains("approximated") == true })
    }

    @Test("An effect that cannot compile falls back and says so")
    func fallsBackWhenUncompilable() throws {
        // Named so the built-in matcher recognises it, then given a shader that will not
        // compile. The approximation should take over rather than the effect disappearing.
        let root = try makeWallpaper(passes: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        try "void main() { notAFunction(); }".write(
            to: root.appendingPathComponent("shaders/swap.frag"), atomically: true, encoding: .utf8
        )
        try #"{"name":"bloom","passes":[{"material":"materials/swap.json"}]}"#.write(
            to: root.appendingPathComponent("effects/swap.json"), atomically: true, encoding: .utf8
        )

        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "swap", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )

        #expect(scene.layers.first?.effects.count == 1)
        #expect(scene.layers.first?.effects.first?.isCompiled == false)
        #expect(scene.report.findings.contains { $0.detail?.contains("approximated") == true })
    }

    @Test("Mixed chains keep the author's order")
    func preservesMixedOrder() {
        // Grouping consecutive approximated steps must not move them past a compiled one.
        let chain: [LayerEffect] = [
            .builtIn(.vignette(intensity: 1)),
            .builtIn(.sharpen(amount: 1)),
            .compiled(CompiledEffect(name: "author", passes: [])),
            .builtIn(.pixelate(size: 2)),
        ]
        #expect(chain.map(\.debugName) == ["vignette", "sharpen", "author", "pixelate"])
        #expect(chain.builtInOnly.count == 3)
    }
}
