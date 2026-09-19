import Foundation
import Metal
import Testing
import WEFormat
@testable import SceneEngine

/// How a scene object reaches the material that draws it.
@Suite("Model indirection")
struct ModelIndirectionTests {

    private func makeWallpaper(
        image: String, files: [String: String]
    ) throws -> (assets: SceneAssets, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaModel-\(UUID().uuidString)", isDirectory: true)
        for (name, body) in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return (SceneAssets(wallpaperID: "m", directory: root, packageURL: nil), root)
    }

    @Test("An object's image path names a model, which names the material")
    func followsModelToMaterial() throws {
        // This is the shape all Workshop content uses, and reading the model file as a material
        // finds no passes and drops the layer. It cost every scene in a real library: 59 of them
        // reported "declares no passes" and rendered one layer between them.
        let (assets, root) = try makeWallpaper(image: "models/thing.json", files: [
            "models/thing.json": #"{"autosize":true,"material":"materials/thing.json"}"#,
            "materials/thing.json": #"{"passes":[{"shader":"genericimage2","textures":["thing"]}]}"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try #require(assets.resolvedMaterial(forImage: "models/thing.json"))
        #expect(resolved.material.firstPass?.shader == "genericimage2")
        #expect(resolved.model?.autosize == true)
    }

    @Test("An object pointing straight at a material still works")
    func acceptsDirectMaterial() throws {
        // Locally authored content does this, and every test before the real library did too.
        let (assets, root) = try makeWallpaper(image: "materials/thing.json", files: [
            "materials/thing.json": #"{"passes":[{"shader":"genericimage2","textures":["thing"]}]}"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try #require(assets.resolvedMaterial(forImage: "materials/thing.json"))
        #expect(resolved.material.firstPass?.shader == "genericimage2")
        #expect(resolved.model == nil)
    }

    @Test("A model naming a material that is not there is reported")
    func missingMaterialReported() throws {
        let (assets, root) = try makeWallpaper(image: "models/thing.json", files: [
            "models/thing.json": #"{"material":"materials/gone.json"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(assets.resolvedMaterial(forImage: "models/thing.json") == nil)
        #expect(assets.report.findings.contains { $0.feature == "Material" })
    }

    @Test("A model naming no material at all is reported as a model problem")
    func modelWithoutMaterial() throws {
        let (assets, root) = try makeWallpaper(image: "models/thing.json", files: [
            "models/thing.json": #"{"autosize":true}"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(assets.resolvedMaterial(forImage: "models/thing.json") == nil)
        #expect(assets.report.findings.contains { $0.feature == "Model" })
    }

    @Test("A puppet skeleton is reported rather than silently ignored")
    func puppetReported() throws {
        // The layer still draws; it just will not deform. Saying so beats the user wondering
        // why a character is stiff.
        let (assets, root) = try makeWallpaper(image: "models/thing.json", files: [
            "models/thing.json": #"{"material":"materials/thing.json","puppet":"models/thing.mdl"}"#,
            "materials/thing.json": #"{"passes":[{"shader":"genericimage2"}]}"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(assets.resolvedMaterial(forImage: "models/thing.json") != nil)
        #expect(assets.report.findings.contains { $0.feature == "Puppet warp" })
    }
}
