import Foundation
import Testing
@testable import WEFormat

@Suite("PKGArchive")
struct PKGArchiveTests {

    // MARK: - Round trip

    @Test("Reads back every file it was given")
    func roundTrip() throws {
        var builder = PKGBuilder()
        builder.add("project.json", #"{"title":"Test"}"#)
        builder.add("materials/wave.json", #"{"passes":[]}"#)
        builder.add("shaders/wave.frag", "void main() {}")

        let archive = try PKGArchive(data: builder.build())

        #expect(archive.version == "PKGV0001")
        #expect(archive.entries.count == 3)
        #expect(archive.contains("project.json"))
        #expect(try archive.data(for: "project.json") == Data(#"{"title":"Test"}"#.utf8))
        #expect(try archive.data(for: "shaders/wave.frag") == Data("void main() {}".utf8))
    }

    @Test("Supports every documented header revision", arguments: [
        "PKGV0001", "PKGV0002", "PKGV0003", "PKGV0004", "PKGV0005",
    ])
    func allVersions(version: String) throws {
        var builder = PKGBuilder(version: version)
        builder.trailingInt32Count = PKGArchive.entryLayout(for: version).trailingInt32Count
        builder.add("a.txt", "alpha")
        builder.add("b.txt", "beta")

        let archive = try PKGArchive(data: builder.build())
        #expect(archive.version == version)
        #expect(try archive.data(for: "b.txt") == Data("beta".utf8))
    }

    @Test("An empty archive is valid, not an error")
    func emptyArchive() throws {
        let archive = try PKGArchive(data: PKGBuilder().build())
        #expect(archive.entries.isEmpty)
        #expect(archive.contains("anything") == false)
    }

    @Test("A zero-length file round-trips")
    func emptyFile() throws {
        var builder = PKGBuilder()
        builder.add("empty.bin", Data())
        let archive = try PKGArchive(data: builder.build())
        #expect(try archive.data(for: "empty.bin").isEmpty)
    }

    @Test("Asking for a file that is not there throws rather than returning empty")
    func missingFile() throws {
        let archive = try PKGArchive(data: PKGBuilder().build())
        #expect(throws: WEError.self) { try archive.data(for: "nope.json") }
    }

    // MARK: - Hostile input
    //
    // Everything below is untrusted third-party content from the Steam Workshop, parsed by a
    // process that runs continuously in the background. None of it may trap, hang, or allocate
    // unboundedly — it must throw a typed error.

    @Test("Rejects a file that is not a package at all")
    func notAPackage() {
        var data = Data()
        data.appendLengthPrefixed("ZIPV0001")
        data.appendInt32(0)
        #expect(throws: WEError.self) { try PKGArchive(data: data) }
    }

    @Test("Distinguishes an unknown revision from a wrong file type")
    func futureVersion() {
        var data = Data()
        data.appendLengthPrefixed("PKGV9999")
        data.appendInt32(0)

        // The distinction matters: one is a mis-detected file, the other is a feature request.
        #expect(throws: WEError.unsupportedVersion("PKGV9999")) { try PKGArchive(data: data) }
    }

    @Test("Survives an absurd entry count without allocating")
    func absurdEntryCount() {
        var data = Data()
        data.appendLengthPrefixed("PKGV0001")
        data.appendInt32(Int32.max)
        #expect(throws: WEError.self) { try PKGArchive(data: data) }
    }

    @Test("Rejects a negative entry count")
    func negativeEntryCount() {
        var data = Data()
        data.appendLengthPrefixed("PKGV0001")
        data.appendInt32(-5)
        #expect(throws: WEError.self) { try PKGArchive(data: data) }
    }

    @Test("Rejects truncation partway through the header")
    func truncatedHeader() throws {
        var builder = PKGBuilder()
        builder.add("a.txt", "alpha")
        let full = builder.build()

        // Every prefix of a valid archive must fail cleanly rather than trap.
        for cut in stride(from: 1, to: full.count, by: 3) {
            let truncated = full.prefix(cut)
            #expect(throws: (any Error).self) {
                let archive = try PKGArchive(data: Data(truncated))
                _ = try archive.data(for: "a.txt")
            }
        }
    }

    @Test("Rejects an entry whose data runs past the end of the blob")
    func offsetPastBlob() {
        var data = Data()
        data.appendLengthPrefixed("PKGV0001")
        data.appendInt32(1)
        data.appendLengthPrefixed("evil.bin")
        data.appendInt32(0)
        data.appendInt32(999_999)   // claims far more data than exists
        data.append(Data([1, 2, 3]))

        #expect(throws: WEError.self) { try PKGArchive(data: data) }
    }

    @Test("Rejects a negative offset")
    func negativeOffset() {
        var data = Data()
        data.appendLengthPrefixed("PKGV0001")
        data.appendInt32(1)
        data.appendLengthPrefixed("evil.bin")
        data.appendInt32(-1)
        data.appendInt32(4)
        data.append(Data([1, 2, 3, 4]))

        #expect(throws: WEError.self) { try PKGArchive(data: data) }
    }

    @Test(
        "Rejects path traversal",
        arguments: ["../../../etc/passwd", "/etc/passwd", "a/../../b", "..\\..\\windows"]
    )
    func pathTraversal(path: String) {
        var data = Data()
        data.appendLengthPrefixed("PKGV0001")
        data.appendInt32(1)
        data.appendLengthPrefixed(path)
        data.appendInt32(0)
        data.appendInt32(1)
        data.append(Data([0]))

        // Extraction writes these paths to disk, so a traversal here is an arbitrary-write bug.
        #expect(throws: WEError.self) { try PKGArchive(data: data) }
    }

    @Test("Normalizes Windows separators")
    func windowsSeparators() throws {
        var data = Data()
        data.appendLengthPrefixed("PKGV0001")
        data.appendInt32(1)
        data.appendLengthPrefixed("materials\\wave.json")
        data.appendInt32(0)
        data.appendInt32(2)
        data.append(Data("{}".utf8))

        let archive = try PKGArchive(data: data)
        #expect(archive.contains("materials/wave.json"))
    }

    @Test("An empty buffer fails cleanly")
    func emptyBuffer() {
        #expect(throws: (any Error).self) { try PKGArchive(data: Data()) }
    }
}
