import CoreGraphics
import Foundation
import Metal
import MetalRenderer
import ShaderTranspiler
import Testing
import WEFormat
@testable import SceneEngine


/// Renders a scene end to end and checks that the material's own shader is what produced the
/// pixels — not the built-in quad shader it used to fall back to.
@Suite(
    "Material render path",
    .enabled(if: gpuAndToolchainAvailable, "needs a GPU and the vendored shader toolchain")
)
struct MaterialRenderPathTests {

    /// Outputs a colour no other path in the renderer produces, so seeing it in the output is
    /// proof this shader ran rather than the built-in one.
    private static let markerFragment = """
    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }
    """

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

    private func makeWallpaper(fragment: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaRenderPath-\(UUID().uuidString)", isDirectory: true)
        let shaders = root.appendingPathComponent("shaders", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: shaders, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)

        try Self.vertex.write(
            to: shaders.appendingPathComponent("marker.vert"), atomically: true, encoding: .utf8
        )
        try fragment.write(
            to: shaders.appendingPathComponent("marker.frag"), atomically: true, encoding: .utf8
        )

        let material = """
        {"passes":[{"blending":"normal","shader":"marker","textures":["materials/none"]}]}
        """
        try material.write(
            to: materials.appendingPathComponent("layer.json"), atomically: true, encoding: .utf8
        )

        let scene = """
        {
          "general": { "orthogonalprojection": { "width": 64, "height": 64 },
                       "clearcolor": "0 0 0" },
          "objects": [
            { "image": "materials/layer.json", "name": "marker",
              "origin": "0 0 0", "size": "64 64", "visible": true }
          ]
        }
        """
        try scene.write(
            to: root.appendingPathComponent("scene.json"), atomically: true, encoding: .utf8
        )
        return root
    }

    private func renderCentrePixel(root: URL) throws -> (r: UInt8, g: UInt8, b: UInt8)? {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(renderDevice: try RenderDevice(device: device))
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "marker", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )
        renderer.setScene(scene)

        guard let image = renderer.renderOffscreen(width: 32, height: 32) else { return nil }
        guard let data = image.dataProvider?.data as Data? else { return nil }

        let bytesPerRow = image.bytesPerRow
        let middle = (16 * bytesPerRow) + 16 * 4
        guard middle + 3 < data.count else { return nil }

        // BGRA8, which is what the offscreen target uses.
        return (data[middle + 2], data[middle + 1], data[middle])
    }

    @Test("A layer is drawn by its own shader, not the built-in one")
    func materialShaderProducesThePixels() throws {
        // The built-in quad shader multiplies the texture by the tint; it cannot produce pure
        // green from a white fallback texture and a white tint. Seeing green means the
        // material's own fragment shader ran.
        let root = try makeWallpaper(fragment: Self.markerFragment)
        defer { try? FileManager.default.removeItem(at: root) }

        let pixel = try #require(try renderCentrePixel(root: root))
        #expect(pixel.g > 200)
        #expect(pixel.r < 60)
        #expect(pixel.b < 60)
    }

    @Test("A shader that will not compile falls back instead of dropping the layer")
    func brokenShaderFallsBack() throws {
        // A wallpaper missing one effect is still recognisably itself; a wallpaper missing a
        // layer is not. The fallback draws the layer through the built-in shader, which with no
        // texture means the white placeholder.
        let root = try makeWallpaper(fragment: "void main() { notAFunction(); }")
        defer { try? FileManager.default.removeItem(at: root) }

        let pixel = try #require(try renderCentrePixel(root: root))
        #expect(pixel.r > 200)
        #expect(pixel.g > 200)
        #expect(pixel.b > 200)
    }

    @Test("The failure is reported, not silently swallowed")
    func brokenShaderIsReported() throws {
        let root = try makeWallpaper(fragment: "void main() { notAFunction(); }")
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "marker", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )
        #expect(scene.report.findings.contains { $0.feature == "Shader" })
    }

    @Test("Uniforms reach the shader")
    func uniformsAreBound() throws {
        // Drives the output colour entirely from a material-supplied uniform, so the pixel is
        // only right if the constant buffer was filled and bound at the slot the translator
        // reported. A wrong offset or slot gives black.
        let fragment = #"""
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform vec4 g_Tint; // {"material":"tint","default":"0 0 1 1","type":"color"}
        void main() { gl_FragColor = g_Tint; }
        """#
        let root = try makeWallpaper(fragment: fragment)
        defer { try? FileManager.default.removeItem(at: root) }

        let pixel = try #require(try renderCentrePixel(root: root))
        #expect(pixel.b > 200)
        #expect(pixel.r < 60)
        #expect(pixel.g < 60)
    }

    @Test("The vertex shader's own transform places the layer")
    func vertexTransformApplies() throws {
        // Off-centre by half the scene, so the centre pixel must be background. If the vertex
        // uniform block were unbound the matrix would read as zeroes and collapse the quad to a
        // point, which would also leave the centre clear — so the paired test above, where the
        // layer does cover the centre, is what rules that out.
        let root = try makeWallpaper(fragment: Self.markerFragment)
        defer { try? FileManager.default.removeItem(at: root) }

        let scene = try String(contentsOf: root.appendingPathComponent("scene.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"origin\": \"0 0 0\"", with: "\"origin\": \"200 0 0\"")
        try scene.write(
            to: root.appendingPathComponent("scene.json"), atomically: true, encoding: .utf8
        )

        let pixel = try #require(try renderCentrePixel(root: root))
        #expect(pixel.g < 60)
    }

    @Test("A user setting reaches the shader on the next frame")
    func propertyOverrideChangesThePixels() throws {
        // The whole chain: a project.json property key, the annotation on the uniform that names
        // it, the override dictionary, the constant buffer, and the shader that reads it. The
        // wallpaper's own default is blue; the user's setting is green.
        let fragment = #"""
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform vec4 g_Tint; // {"material":"tint","default":"0 0 1 1","type":"color"}
        void main() { gl_FragColor = g_Tint; }
        """#
        let root = try makeWallpaper(fragment: fragment)
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(renderDevice: try RenderDevice(device: device))
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "marker", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )
        renderer.setScene(scene)

        func centre() throws -> (r: UInt8, g: UInt8, b: UInt8) {
            let image = try #require(renderer.renderOffscreen(width: 32, height: 32))
            let data = try #require(image.dataProvider?.data as Data?)
            let middle = (16 * image.bytesPerRow) + 16 * 4
            return (data[middle + 2], data[middle + 1], data[middle])
        }

        let authored = try centre()
        #expect(authored.b > 200)

        // Applied without rebuilding the scene: changing a setting must not recompile shaders
        // or reload textures, or every tick of a slider would flash.
        renderer.propertyOverrides = ["tint": .string("0 1 0 1")]
        let overridden = try centre()
        #expect(overridden.g > 200)
        #expect(overridden.b < 60)

        // And clearing it puts the author's value back rather than leaving the last one.
        renderer.propertyOverrides = [:]
        #expect(try centre().b > 200)
    }

    @Test("A uniform block larger than Metal's inline limit still binds")
    func largeUniformBlockBinds() throws {
        // Metal's setBytes fast path stops at 4KB; past that the data has to go in a buffer, and
        // that branch had never been exercised. The colour comes from a uniform sitting past
        // 4800 bytes, so it is only right if the whole block was uploaded rather than truncated.
        let fragment = #"""
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform float g_Weights[300];
        uniform vec4 g_Tint; // {"material":"tint","default":"0 1 0 1","type":"color"}
        void main() { gl_FragColor = g_Tint + vec4(g_Weights[299] * 0.0); }
        """#
        let root = try makeWallpaper(fragment: fragment)
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(renderDevice: try RenderDevice(device: device))
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "big", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )
        // The block must genuinely exceed the inline limit or this tests the wrong branch.
        let layout = try #require(scene.layers.first?.program?.fragmentLayout)
        #expect(layout.size > MaterialRenderer.inlineByteLimit)

        renderer.setScene(scene)
        let image = try #require(renderer.renderOffscreen(width: 32, height: 32))
        let data = try #require(image.dataProvider?.data as Data?)
        let middle = (16 * image.bytesPerRow) + 16 * 4

        #expect(data[middle + 1] > 200, "green from a uniform past the inline limit was lost")
        #expect(data[middle + 2] < 60)
    }

    @Test("A large block survives a second frame on the reused buffer")
    func largeBlockReusesBuffer() throws {
        // The scratch buffer is kept per program so a shader with big uniform arrays does not
        // allocate one per draw. Reuse is where a stale or wrongly-sized buffer would show up.
        let fragment = #"""
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform float g_Weights[300];
        uniform vec4 g_Tint; // {"material":"tint","default":"0 0 1 1","type":"color"}
        void main() { gl_FragColor = g_Tint + vec4(g_Weights[299] * 0.0); }
        """#
        let root = try makeWallpaper(fragment: fragment)
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(renderDevice: try RenderDevice(device: device))
        renderer.setScene(try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "big", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        ))

        func blueAtCentre() throws -> UInt8 {
            let image = try #require(renderer.renderOffscreen(width: 32, height: 32))
            let data = try #require(image.dataProvider?.data as Data?)
            return data[(16 * image.bytesPerRow) + 16 * 4]
        }

        #expect(try blueAtCentre() > 200)
        renderer.propertyOverrides = ["tint": .string("0 1 0")]
        #expect(try blueAtCentre() < 60, "an override did not reach the reused buffer")
        renderer.propertyOverrides = [:]
        #expect(try blueAtCentre() > 200, "the buffer kept the previous frame's value")
    }

    @Test("A shader failure reports why, not just what the backend said")
    func failureCarriesPreprocessorFindings() throws {
        // glslang answers an unreadable uniform declaration with "non-opaque uniforms outside a
        // block", which describes a rule the author never wrote against. The preprocessor
        // already knows it could not read the declaration, and that is the actionable half.
        let root = try makeWallpaper(fragment: """
        uniform vec4 g_Missing
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = g_Missing; }
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "broken", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )

        let details = scene.report.findings.compactMap(\.detail)
        #expect(details.contains { $0.contains("Could not read this uniform declaration") })
    }

    @Test("A wallpaper whose shader fails is degraded, not unsupported")
    func shaderFailureIsDegraded() throws {
        // The layer still draws through the built-in shader with its own textures, so the
        // wallpaper looks like itself, flatter. Reserving `unsupported` for "nothing renders"
        // is what keeps the word meaning something in a library-wide report.
        let root = try makeWallpaper(fragment: "void main() { notAFunction(); }")
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "broken", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )

        #expect(scene.report.level != .unsupported)
        #expect(!scene.layers.isEmpty)
    }

    @Test("A backend error names the author's line, not the emitted one")
    func backendErrorsUseAuthorLines() throws {
        // Three blank lines above the error, so the emitted line number (shifted by the
        // prologue) and the author's cannot coincide by accident.
        let root = try makeWallpaper(fragment: """


        varying vec2 v_TexCoord;
        void main() { notAFunction(); }
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "broken", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        )

        let shaderFindings = scene.report.findings.filter { $0.feature == "Shader" }
        #expect(!shaderFindings.isEmpty)
        // The offending line is 4 in the file the author wrote. Without the remap this would
        // name a line in the emitted GLSL, which is shifted by the prologue and has flattened
        // every include into one buffer — a line nobody can open.
        #expect(shaderFindings.contains { $0.detail?.contains("marker.frag:4") == true })
    }
}
