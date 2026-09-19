import CoreGraphics
import Diagnostics
import Foundation
import Metal
import MetalRenderer
import ShaderTranspiler
import Testing
import WEFormat
@testable import SceneEngine

/// Effect chains shaped the way a badly-behaved or unusual wallpaper might write one.
@Suite(
    "Effect chain edge cases",
    .enabled(if: gpuAndToolchainAvailable, "needs a GPU and the vendored shader toolchain")
)
struct EffectChainHazardTests {

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

    private static let passthrough = """
    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    void main() { gl_FragColor = texture2D(g_Texture0, v_TexCoord); }
    """

    /// Builds a wallpaper whose single layer carries `effect`, given as the JSON `passes` array.
    private func makeWallpaper(passesJSON: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaHazard-\(UUID().uuidString)", isDirectory: true)
        for folder in ["shaders", "materials", "effects"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Self.vertex.write(
            to: root.appendingPathComponent("shaders/pass.vert"), atomically: true, encoding: .utf8
        )
        try Self.passthrough.write(
            to: root.appendingPathComponent("shaders/pass.frag"), atomically: true, encoding: .utf8
        )
        try #"{"passes":[{"blending":"normal","shader":"pass","textures":["none"]}]}"#.write(
            to: root.appendingPathComponent("materials/pass.json"), atomically: true, encoding: .utf8
        )
        try #"{"name":"hazard","passes":\#(passesJSON)}"#.write(
            to: root.appendingPathComponent("effects/hazard.json"), atomically: true, encoding: .utf8
        )
        try """
        {
          "general": { "orthogonalprojection": { "width": 64, "height": 64 },
                       "clearcolor": "0 0 0" },
          "objects": [
            { "image": "materials/pass.json", "name": "base", "origin": "32 32 0",
              "size": "64 64", "visible": true,
              "effects": [ { "file": "effects/hazard.json", "visible": true } ] }
          ]
        }
        """.write(to: root.appendingPathComponent("scene.json"), atomically: true, encoding: .utf8)
        return root
    }

    @discardableResult
    private func render(_ root: URL) throws -> CGImage? {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(renderDevice: try RenderDevice(device: device))
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "hazard", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )
        renderer.setScene(scene)
        return renderer.renderOffscreen(width: 32, height: 32)
    }

    @Test("A pass that reads the target it writes does not corrupt the frame")
    func readWriteSameTarget() throws {
        // Metal forbids a texture being a render target and a shader resource at once. A chain
        // written this way is unusual but nothing stops a wallpaper shipping one, and it must
        // degrade rather than produce a validation failure or undefined pixels.
        let root = try makeWallpaper(passesJSON: #"""
        [{"material":"materials/pass.json","target":"_rt_a",
          "bind":[{"index":0,"name":"_rt_a"}]},
         {"material":"materials/pass.json",
          "bind":[{"index":0,"name":"_rt_a"}]}]
        """#)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try render(root) != nil)
    }

    @Test("A long chain does not exhaust the frame buffer pool")
    func longChain() throws {
        // Each named target takes a pooled texture for the life of the chain. Eight distinct
        // ones is more than any shipped effect, and the chain must still complete.
        let passes = (0 ..< 8).map { index in
            let bind = index == 0 ? "" : #","bind":[{"index":0,"name":"_rt_\#(index - 1)"}]"#
            return #"{"material":"materials/pass.json","target":"_rt_\#(index)"\#(bind)}"#
        }.joined(separator: ",")
        let root = try makeWallpaper(passesJSON: "[\(passes)]")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try render(root) != nil)
    }

    @Test("A pass naming a material that is not there falls back rather than half-running")
    func missingMaterialFallsBack() throws {
        // Half an effect looks like a rendering bug; the built-in approximation at least looks
        // like the effect it is named after.
        let root = try makeWallpaper(passesJSON: #"""
        [{"material":"materials/pass.json","target":"_rt_a"},
         {"material":"materials/nope.json","bind":[{"index":0,"name":"_rt_a"}]}]
        """#)
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "hazard", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )
        #expect(scene.layers.first?.effects.allSatisfy { !$0.isCompiled } == true)
        #expect(try render(root) != nil)
    }

    @Test("An effect declaring no passes is not treated as a compiled one")
    func emptyEffect() throws {
        let root = try makeWallpaper(passesJSON: "[]")
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "hazard", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )
        #expect(scene.layers.first?.effects.contains(where: \.isCompiled) != true)
        #expect(try render(root) != nil)
    }

    @Test("A pass reading the target it writes is given a fresh one")
    func readWriteGetsFreshTarget() throws {
        // Asserted on the runner rather than on pixels, and deliberately so. On a tile-based
        // GPU, sampling a texture you are also rendering into returns its pre-clear contents
        // from device memory, so the broken version produces the right colours on this hardware
        // and undefined ones elsewhere — a pixel test passes either way and proves nothing.
        // (Checked: an earlier pixel version of this test passed with the fix reverted.)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderDevice = try RenderDevice(device: device)
        let runner = EffectChainRunner(materials: try MaterialRenderer(device: device))
        let pool = FBOPool(device: device)

        let root = try makeWallpaper(passesJSON: #"""
        [{"material":"materials/pass.json","target":"_rt_a"},
         {"material":"materials/pass.json","target":"_rt_a",
          "bind":[{"index":0,"name":"_rt_a"}]},
         {"material":"materials/pass.json","bind":[{"index":0,"name":"_rt_a"}]}]
        """#)
        defer { try? FileManager.default.removeItem(at: root) }

        let assets = SceneAssets(wallpaperID: "hazard", directory: root, packageURL: nil)
        let document = try JSONDecoder().decode(
            EffectDocument.self,
            from: try #require(assets.data(for: "effects/hazard.json"))
        )
        var report = CompatibilityReport(wallpaperID: "hazard")
        let compiler = MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        let effect = try #require(
            compiler.effect(for: document, assets: assets, device: device, report: &report)
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let destination = try #require(device.makeTexture(descriptor: descriptor))

        let buffer = try #require(renderDevice.makeRetainedCommandBuffer(label: "hazard"))
        let ran = runner.run(
            effect, source: source, destination: destination,
            engine: EngineUniforms(), commandBuffer: buffer, pool: pool
        )
        buffer.commit()
        buffer.waitUntilCompleted()

        #expect(ran)
        // Exactly the middle pass: the first writes a target nothing has yet, the last writes
        // the chain's destination.
        #expect(runner.hazardsAvoided == 1)
    }

    @Test("A chain with no read-write overlap does not allocate extra targets")
    func noHazardNoExtraTargets() throws {
        // The fix must not fire on ordinary ping-ponging between two distinct targets, which is
        // what most real chains do — paying for an extra frame buffer per pass would be a
        // memory regression on every wallpaper with effects.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderDevice = try RenderDevice(device: device)
        let runner = EffectChainRunner(materials: try MaterialRenderer(device: device))
        let pool = FBOPool(device: device)

        let root = try makeWallpaper(passesJSON: #"""
        [{"material":"materials/pass.json","target":"_rt_a"},
         {"material":"materials/pass.json","target":"_rt_b",
          "bind":[{"index":0,"name":"_rt_a"}]},
         {"material":"materials/pass.json","bind":[{"index":0,"name":"_rt_b"}]}]
        """#)
        defer { try? FileManager.default.removeItem(at: root) }

        let assets = SceneAssets(wallpaperID: "hazard", directory: root, packageURL: nil)
        let document = try JSONDecoder().decode(
            EffectDocument.self,
            from: try #require(assets.data(for: "effects/hazard.json"))
        )
        var report = CompatibilityReport(wallpaperID: "hazard")
        let compiler = MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        let effect = try #require(
            compiler.effect(for: document, assets: assets, device: device, report: &report)
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let destination = try #require(device.makeTexture(descriptor: descriptor))
        let buffer = try #require(renderDevice.makeRetainedCommandBuffer(label: "hazard"))

        #expect(runner.run(
            effect, source: source, destination: destination,
            engine: EngineUniforms(), commandBuffer: buffer, pool: pool
        ))
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(runner.hazardsAvoided == 0)
    }
}
