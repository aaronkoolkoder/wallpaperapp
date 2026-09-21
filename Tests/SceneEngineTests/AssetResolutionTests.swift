import Foundation
import Metal
import Testing
import WEFormat
@testable import SceneEngine

@Suite("SceneAssets package handling")
struct SceneAssetsPackageTests {

    private func temporaryWallpaper() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaAssets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A loose scene.json is not reported as an unreadable package")
    func looseSceneIsNotAPackage() throws {
        // A wallpaper authored in the editor names scene.json as its content file, and the
        // audit passes that same URL through as the package. Reading it as an archive fails, so
        // every such wallpaper was reported as having an unreadable package — and because a
        // missing package is `unsupported`, the whole wallpaper was scored unsupported.
        let root = try temporaryWallpaper()
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = root.appendingPathComponent("scene.json")
        try #"{"objects":[]}"#.write(to: scene, atomically: true, encoding: .utf8)

        let assets = SceneAssets(wallpaperID: "loose", directory: root, packageURL: scene)
        #expect(!assets.report.findings.contains { $0.feature == "Package" })
        #expect(assets.report.level != .unsupported)
    }

    @Test("A genuinely corrupt package is still reported")
    func corruptPackageIsReported() throws {
        let root = try temporaryWallpaper()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("scene.pkg")
        try Data("not an archive".utf8).write(to: package)

        let assets = SceneAssets(wallpaperID: "corrupt", directory: root, packageURL: package)
        #expect(assets.report.findings.contains { $0.feature == "Package" })
    }

    @Test("A package that is not there is not a finding")
    func missingPackageIsSilent() throws {
        // Plenty of wallpapers legitimately have no package at all.
        let root = try temporaryWallpaper()
        defer { try? FileManager.default.removeItem(at: root) }

        let assets = SceneAssets(
            wallpaperID: "none", directory: root,
            packageURL: root.appendingPathComponent("scene.pkg")
        )
        #expect(!assets.report.findings.contains { $0.feature == "Package" })
    }
}

@Suite("Shader message text")
struct ShaderMessageTextTests {

    @Test("A multi-line compiler error becomes one readable line")
    func collapsesCompilerOutput() {
        // Dropped in verbatim, this breaks the findings list and buries everything after it.
        let raw = """
        parse failed:
        ERROR: 0:2: 'notAFunction' : no matching overloaded function found
        ERROR: 0:2: '' : compilation terminated

        ERROR: 2 compilation errors.  No code generated.
        """
        let line = ShaderMessageText.oneLine(raw)

        #expect(!line.contains("\n"))
        // "parse failed:" alone says nothing, so the line after it is carried along.
        #expect(line.contains("notAFunction"))
        // The trailing count repeats what the report already tallies.
        #expect(!line.contains("No code generated"))
        #expect(line.contains("+1 more"))
    }

    @Test("A single-line message is left as it is")
    func leavesSingleLines() {
        let message = "Shader \"water\" is missing a stage."
        #expect(ShaderMessageText.oneLine(message) == message)
    }

    @Test("A very long message is truncated rather than wrapping the report")
    func truncatesLongMessages() {
        let line = ShaderMessageText.oneLine(String(repeating: "x", count: 400))
        #expect(line.count <= ShaderMessageText.limit)
        #expect(line.hasSuffix("…"))
    }

    @Test("Empty input does not crash")
    func handlesEmpty() {
        #expect(ShaderMessageText.oneLine("") == "")
        #expect(ShaderMessageText.oneLine("\n\n") == "\n\n")
    }
}

/// Which filenames a texture reference is allowed to mean.
@Suite("SceneAssets path variants")
struct SceneAssetsPathVariantTests {

    @Test("A dot inside an asset's name is part of the name, not an extension")
    func dottedNameStillFindsItsTexture() {
        // Real Workshop content: the layer's texture is stored as
        // `materials/<name>.tex` where the name itself ends in `.com-4K-7.3257`. Reading the
        // trailing `.3257` as a file extension meant that candidate was never generated, the
        // texture was reported missing, and the layer drew as a flat white rectangle over the
        // whole desktop.
        let name = "satoru-gojo-hollow-purple-jujutsu-kaisen-uhdpaper.com-4K-7.3257"
        let variants = SceneAssets.pathVariants(name)

        #expect(variants.contains("materials/\(name).tex"), "the real file is never looked for")
        #expect(variants.contains("\(name).tex"))
    }

    @Test("A reference that really does carry an extension still finds the built texture")
    func extensionIsStillStripped() {
        // A material naming `clouds.png` means the texture compiled from it, `clouds.tex`.
        let variants = SceneAssets.pathVariants("clouds.png")
        #expect(variants.contains("clouds.tex"))
        #expect(variants.contains("materials/clouds.tex"))
    }

    @Test("An extensionless reference is unchanged in what it can mean")
    func plainNameKeepsItsCandidates() {
        let variants = SceneAssets.pathVariants("util/noise")
        #expect(variants.contains("util/noise.tex"))
        #expect(variants.contains("materials/util/noise.tex"))
    }

    @Test("No candidate is tried twice")
    func variantsAreDistinct() {
        let variants = SceneAssets.pathVariants("materials/thing")
        #expect(Set(variants).count == variants.count)
    }
}
