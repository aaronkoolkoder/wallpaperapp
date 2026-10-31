import Foundation
import Metal
import MetalRenderer
import ShaderTranspiler
import Testing
import WEFormat
@testable import SceneEngine

/// Scene time reaching the shaders that animate on it.
///
/// Counting frames proves the loop runs, not that anything moves: a wallpaper whose clock never
/// advances renders exactly as many frames as a working one, and every single-frame check in
/// this suite passes on it.
@Suite(
    "Animation",
    .enabled(if: gpuAndToolchainAvailable, "needs a GPU and the vendored shader toolchain")
)
struct AnimationTests {

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

    /// Ramps from black to red over four seconds, so the frame is a direct readout of `g_Time`.
    private static let clockFragment = """
    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform float g_Time;
    void main() { gl_FragColor = vec4(fract(g_Time * 0.25), 0.0, 0.0, 1.0); }
    """

    private func makeWallpaper() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaAnim-\(UUID().uuidString)", isDirectory: true)
        for folder in ["shaders", "materials"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let shaders = root.appendingPathComponent("shaders", isDirectory: true)
        try Self.vertex.write(
            to: shaders.appendingPathComponent("clock.vert"), atomically: true, encoding: .utf8
        )
        try Self.clockFragment.write(
            to: shaders.appendingPathComponent("clock.frag"), atomically: true, encoding: .utf8
        )
        try #"{"passes":[{"blending":"normal","shader":"clock","textures":["none"]}]}"#.write(
            to: root.appendingPathComponent("materials/clock.json"), atomically: true, encoding: .utf8
        )
        try """
        {
          "general": { "orthogonalprojection": { "width": 64, "height": 64 },
                       "clearcolor": "0 0 0" },
          "objects": [
            { "image": "materials/clock.json", "name": "base", "origin": "32 32 0",
              "size": "64 64", "visible": true }
          ]
        }
        """.write(to: root.appendingPathComponent("scene.json"), atomically: true, encoding: .utf8)
        return root
    }

    private func renderer(_ root: URL) throws -> SceneRenderer {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(renderDevice: try RenderDevice(device: device))
        renderer.setScene(try SceneRenderer.loadScene(
            directory: root, packageURL: nil, wallpaperID: "anim", device: device,
            materials: MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        ))
        return renderer
    }

    private func red(_ renderer: SceneRenderer, after seconds: Float) throws -> UInt8 {
        let image = try #require(renderer.renderOffscreen(width: 16, height: 16, warmUpSeconds: seconds))
        let data = try #require(image.dataProvider?.data as Data?)
        return data[(8 * image.bytesPerRow) + 8 * 4 + 2]   // BGRA
    }

    @Test("A shader reading g_Time draws something different as time passes")
    func timeReachesTheShader() throws {
        let root = try makeWallpaper()
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = try self.renderer(root)

        let first = try red(renderer, after: 0)
        let second = try red(renderer, after: 1)
        let third = try red(renderer, after: 1)

        #expect(second != first, "the frame is identical a second later — nothing animates")
        #expect(third != second, "motion stopped after the first step")
        // A quarter-cycle per second on a 0-255 ramp: about 64 per step, give or take rounding.
        #expect(abs(Int(second) - Int(first) - 64) < 6, "time advanced by the wrong amount")
    }

    @Test("Scene time advances by the wall-clock gap between frames")
    func clockFollowsTheDisplayLink() {
        var clock = SceneClock()
        clock.advance(to: 100.0)          // first frame only seeds it
        #expect(clock.elapsed == 0)

        clock.advance(to: 100.05)
        #expect(abs(clock.elapsed - 0.05) < 1e-5)
        clock.advance(to: 100.10)
        #expect(abs(clock.elapsed - 0.10) < 1e-5)
    }

    @Test("A long gap is clamped rather than jumping the animation")
    func resumeDoesNotJump() {
        // Coming back from occlusion or sleep can leave minutes between frames, and an
        // animation that integrates over dt would lurch or blow up.
        var clock = SceneClock()
        clock.advance(to: 0)
        clock.advance(to: 600)
        #expect(clock.delta <= 0.1)
        #expect(clock.elapsed <= 0.1)
    }
}
