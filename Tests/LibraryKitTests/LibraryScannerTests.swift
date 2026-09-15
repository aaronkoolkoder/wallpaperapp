import Foundation
import Testing
@testable import LibraryKit
import WEFormat

@Suite("LibraryScanner")
struct LibraryScannerTests {

    /// Builds a throwaway Workshop tree. Real Workshop content is not redistributable and never
    /// enters the repo (PLAN.md §11.2), so every fixture is synthesised.
    final class Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("diorama-scan-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("431960"), withIntermediateDirectories: true
            )
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        var contentRoot: URL { root.appendingPathComponent("431960") }

        @discardableResult
        func add(_ id: String, manifest: String, files: [String] = []) throws -> URL {
            let directory = contentRoot.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try manifest.write(
                to: directory.appendingPathComponent("project.json"),
                atomically: true, encoding: .utf8
            )
            for file in files {
                let url = directory.appendingPathComponent(file)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data("x".utf8).write(to: url)
            }
            return directory
        }
    }

    @Test("Indexes a well-formed library")
    func indexesLibrary() throws {
        let fixture = try Fixture()
        try fixture.add(
            "111", manifest: #"{"title":"Rain","type":"video","file":"a.mp4","preview":"p.jpg"}"#,
            files: ["a.mp4", "p.jpg"]
        )
        try fixture.add(
            "222", manifest: #"{"title":"Grid","type":"web","file":"index.html"}"#,
            files: ["index.html"]
        )

        let result = LibraryScanner().scan(root: fixture.root)
        #expect(result.items.count == 2)
        #expect(result.playableCount == 2)
        #expect(result.items.map(\.title) == ["Grid", "Rain"])  // sorted
    }

    @Test("Accepts being pointed at any level of the folder the user copied")
    func resolvesRoot() throws {
        let fixture = try Fixture()
        try fixture.add(
            "111", manifest: #"{"title":"Rain","type":"video","file":"a.mp4"}"#, files: ["a.mp4"]
        )

        // Users copy whichever level they happened to grab, so both must work.
        #expect(LibraryScanner().scan(root: fixture.root).items.count == 1)
        #expect(LibraryScanner().scan(root: fixture.contentRoot).items.count == 1)
    }

    @Test("One malformed wallpaper does not abort the scan")
    func malformedDoesNotAbort() throws {
        let fixture = try Fixture()
        try fixture.add("111", manifest: #"{"title":"Good","type":"video","file":"a.mp4"}"#, files: ["a.mp4"])
        try fixture.add("222", manifest: #"{"title":"Bad",,,"#)
        try fixture.add("333", manifest: #"{"title":"Also Good","type":"web","file":"i.html"}"#, files: ["i.html"])

        let result = LibraryScanner().scan(root: fixture.root)
        // The good ones still land; the bad one is recorded rather than swallowed.
        #expect(result.items.count == 2)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.directory == "222")
    }

    @Test("Windows-only wallpapers are kept and explained, not dropped")
    func applicationTypeExplained() throws {
        let fixture = try Fixture()
        try fixture.add(
            "111", manifest: #"{"title":"Clock","type":"application","file":"c.exe"}"#, files: ["c.exe"]
        )

        let result = LibraryScanner().scan(root: fixture.root)
        let item = try #require(result.items.first)
        // Someone who copies 300 wallpapers and sees 280 needs to know what happened to the rest.
        #expect(item.isPlayable == false)
        #expect(item.unplayableReason?.contains("Windows") == true)
    }

    @Test("A manifest naming a file that is not there reports which file")
    func missingContentFile() throws {
        let fixture = try Fixture()
        try fixture.add("111", manifest: #"{"title":"Broken","type":"video","file":"gone.mp4"}"#)

        let item = try #require(LibraryScanner().scan(root: fixture.root).items.first)
        #expect(item.isPlayable == false)
        #expect(item.unplayableReason?.contains("gone.mp4") == true)
    }

    @Test("An unrecognised type is reported by name")
    func unknownType() throws {
        let fixture = try Fixture()
        try fixture.add("111", manifest: #"{"title":"Future","type":"hologram","file":"x.holo"}"#, files: ["x.holo"])

        let item = try #require(LibraryScanner().scan(root: fixture.root).items.first)
        #expect(item.isPlayable == false)
        #expect(item.unplayableReason?.contains("hologram") == true)
    }

    @Test("Falls back to a conventional preview name when the manifest omits one")
    func previewFallback() throws {
        let fixture = try Fixture()
        try fixture.add(
            "111", manifest: #"{"title":"Rain","type":"video","file":"a.mp4"}"#,
            files: ["a.mp4", "preview.jpg"]
        )

        let item = try #require(LibraryScanner().scan(root: fixture.root).items.first)
        #expect(item.previewURL?.lastPathComponent == "preview.jpg")
    }

    @Test("Falls back to the directory name when a manifest has no title")
    func titleFallback() throws {
        let fixture = try Fixture()
        try fixture.add("999", manifest: #"{"type":"video","file":"a.mp4"}"#, files: ["a.mp4"])

        #expect(LibraryScanner().scan(root: fixture.root).items.first?.title == "999")
    }

    @Test("Per-wallpaper properties survive indexing")
    func propertiesIndexed() throws {
        let fixture = try Fixture()
        try fixture.add("111", manifest: """
        {"title":"Field","type":"web","file":"i.html","general":{"properties":{
          "density":{"type":"slider","text":"Density","value":0.5,"min":0,"max":1},
          "glow":{"type":"bool","text":"Glow","value":true}
        }}}
        """, files: ["i.html"])

        let item = try #require(LibraryScanner().scan(root: fixture.root).items.first)
        #expect(item.properties.count == 2)
        #expect(item.properties["density"]?.max == 1)
    }

    @Test("A directory with no project.json is skipped silently")
    func ignoresNonWallpaperDirectories() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(
            at: fixture.contentRoot.appendingPathComponent("junk"), withIntermediateDirectories: true
        )
        try fixture.add("111", manifest: #"{"title":"Rain","type":"video","file":"a.mp4"}"#, files: ["a.mp4"])

        let result = LibraryScanner().scan(root: fixture.root)
        #expect(result.items.count == 1)
        #expect(result.failures.isEmpty)
    }

    @Test("Scanning a folder that does not exist returns empty rather than throwing")
    func missingRoot() {
        let result = LibraryScanner().scan(root: URL(fileURLWithPath: "/nope/does/not/exist"))
        #expect(result.items.isEmpty)
    }
}
