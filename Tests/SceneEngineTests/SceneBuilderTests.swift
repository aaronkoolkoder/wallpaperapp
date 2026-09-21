import Foundation
import Metal
import MetalRenderer
import Testing
import WEFormat
import simd
@testable import SceneEngine

@Suite("SceneBuilder")
struct SceneBuilderTests {

    @Test("Maps Wallpaper Engine blend names onto premultiplied modes")
    func blendModeNames() {
        #expect(SceneBuilder.blendMode(named: "additive") == .premultipliedAdditive)
        #expect(SceneBuilder.blendMode(named: "multiply") == .premultipliedMultiply)
        #expect(SceneBuilder.blendMode(named: "screen") == .premultipliedScreen)
        #expect(SceneBuilder.blendMode(named: "normal") == .premultipliedAlpha)
    }

    @Test("Blend names are case-insensitive and default safely")
    func blendModeFallback() {
        #expect(SceneBuilder.blendMode(named: "ADDITIVE") == .premultipliedAdditive)
        // An unrecognised or absent mode must render, not vanish.
        #expect(SceneBuilder.blendMode(named: nil) == .premultipliedAlpha)
        #expect(SceneBuilder.blendMode(named: "somethingnew") == .premultipliedAlpha)
    }

    @Test("Model matrix translates to the layer's origin")
    func modelMatrixTranslation() {
        var layer = testLayer()
        layer.origin = SIMD3(100, -50, 0)
        let matrix = layer.modelMatrix
        #expect(matrix.columns.3.x == 100)
        #expect(matrix.columns.3.y == -50)
    }

    @Test("Model matrix applies size and scale together")
    func modelMatrixScale() {
        var layer = testLayer()
        layer.size = SIMD2(200, 100)
        layer.scale = SIMD3(2, 3, 1)
        let matrix = layer.modelMatrix
        #expect(matrix.columns.0.x == 400)
        #expect(matrix.columns.1.y == 300)
    }

    @Test("Rotation spins the layer in place rather than orbiting the scene origin")
    func rotationIsInPlace() {
        var layer = testLayer()
        layer.origin = SIMD3(500, 0, 0)
        layer.size = SIMD2(1, 1)
        layer.angles = SIMD3(0, 0, .pi / 2)

        // Translation must survive rotation untouched. Applying the matrices in the wrong order
        // sends the layer orbiting the origin, which looks like a physics bug rather than a
        // matrix bug and is miserable to track down from a screenshot.
        let matrix = layer.modelMatrix
        #expect(abs(matrix.columns.3.x - 500) < 0.001)
        #expect(abs(matrix.columns.3.y) < 0.001)
    }

    @Test("Projection maps the ortho box onto clip space from its corner")
    func projectionCentred() {
        let scene = RenderableScene(
            layers: [], orthoSize: SIMD2(1920, 1080),
            clearColor: SIMD4(0, 0, 0, 1),
            cameraMotion: CameraMotion(isEnabled: false),
            report: .init(wallpaperID: "t")
        )
        let projection = scene.projectionMatrix

        // Wallpaper Engine measures from a *corner*, so the box spans 0...width, not
        // -half...+half. Real content proved it: a full-bleed layer in a 1920x1080 scene is
        // placed at "960 540 0", and reading that as an offset from the middle put every
        // wallpaper's background in one quadrant.
        let centre = projection * SIMD4<Float>(960, 540, 0, 1)
        #expect(abs(centre.x) < 0.001 && abs(centre.y) < 0.001)

        let rightEdge = projection * SIMD4<Float>(1920, 540, 0, 1)
        #expect(abs(rightEdge.x - 1) < 0.001)
        let leftEdge = projection * SIMD4<Float>(0, 540, 0, 1)
        #expect(abs(leftEdge.x + 1) < 0.001)
        let topEdge = projection * SIMD4<Float>(960, 1080, 0, 1)
        #expect(abs(topEdge.y - 1) < 0.001)
    }

    @Test("Builds layers from a scene document and reports what it cannot draw")
    func buildsFromDocument() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try SceneFixture()

        let document = try JSONDecoder().decode(
            SceneDocument.self, from: Data(SceneFixture.sceneJSON.utf8)
        )
        let assets = SceneAssets(
            wallpaperID: "t", directory: fixture.directory, packageURL: nil
        )
        let scene = SceneBuilder().build(document: document, assets: assets, device: device)

        #expect(scene.layers.count == 1)
        #expect(scene.layers.first?.name == "Backdrop")
        #expect(scene.orthoSize == SIMD2(1920, 1080))

        // The fixture names a particle file that does not exist. That must be reported with
        // the path, not silently dropped — a scene missing its snow should say why.
        #expect(scene.report.level == .degraded)
        #expect(scene.report.findings.contains {
            $0.feature == "Particle system" && $0.detail?.contains("particles/dust.json") == true
        })
    }

    @Test("A missing material degrades that layer without failing the scene")
    func missingMaterialDegrades() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try SceneFixture(writeMaterial: false)

        let document = try JSONDecoder().decode(
            SceneDocument.self, from: Data(SceneFixture.sceneJSON.utf8)
        )
        let assets = SceneAssets(wallpaperID: "t", directory: fixture.directory, packageURL: nil)
        let scene = SceneBuilder().build(document: document, assets: assets, device: device)

        #expect(scene.layers.isEmpty)
        #expect(scene.report.findings.contains { $0.feature == "Material" })
    }

    // MARK: - Helpers

    @Test("Saved angles are radians")
    func anglesAreRadians() throws {
        // Real content stores a quarter turn as 1.5708 and a half turn as 3.107: radians. Read as
        // degrees, a layer authored upright on its side was drawn about a degree and a half off
        // level — 102 rotated objects in a real library.
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-angles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materials"), withIntermediateDirectories: true
        )
        try Data(#"{"passes":[{"shader":"genericimage2","textures":[]}]}"#.utf8)
            .write(to: root.appendingPathComponent("materials/solid.json"))
        let document = try JSONDecoder().decode(SceneDocument.self, from: Data("""
        {"objects":[{"id":1,"name":"Upright","image":"materials/solid.json",
                     "size":"10 10","angles":"0.00000 0.00000 1.57080"}]}
        """.utf8))
        let scene = SceneBuilder().build(
            document: document,
            assets: SceneAssets(wallpaperID: "angles", directory: root, packageURL: nil),
            device: device
        )
        let layer = try #require(scene.layers.first)
        #expect(abs(layer.angles.z - 1.5708) < 0.0001)
    }

    private func testLayer() -> RenderableLayer {
        RenderableLayer(
            name: "test", origin: .zero, angles: .zero, scale: SIMD3(1, 1, 1),
            size: SIMD2(1, 1), tint: SIMD4(1, 1, 1, 1), blend: .premultipliedAlpha,
            texture: nil, parallaxDepth: .zero, isVisible: true
        )
    }

    /// A loose-on-disk wallpaper. Real Workshop content never enters the repo, so scenes under
    /// test are synthesised (PLAN.md §11.2).
    final class SceneFixture {
        let directory: URL

        static let sceneJSON = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
           {"id":1,"name":"Backdrop","image":"materials/bg.json","origin":"0 0 0"},
           {"id":2,"name":"Dust","particle":"particles/dust.json","origin":"0 0 0"}
         ]}
        """

        init(writeMaterial: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("diorama-scene-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("materials"), withIntermediateDirectories: true
            )
            if writeMaterial {
                let material = #"{"passes":[{"blending":"normal","shader":"genericimage2","textures":[]}]}"#
                try material.write(
                    to: directory.appendingPathComponent("materials/bg.json"),
                    atomically: true, encoding: .utf8
                )
            }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }
}
