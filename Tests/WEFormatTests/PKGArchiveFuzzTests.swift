import Foundation
import Testing
@testable import WEFormat

@Suite("PKGArchive fuzzing")
struct PKGArchiveFuzzTests {

    /// Deterministic, so a failure is reproducible from the seed printed in the message.
    private struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func byte() -> UInt8 { UInt8(next() & 0xFF) }
        mutating func int(_ bound: Int) -> Int { bound <= 0 ? 0 : Int(next() % UInt64(bound)) }
    }

    @Test("Random bytes behind a valid signature never crash or hang")
    func fuzzBodies() {
        // Accepting any PKGV revision widened what reaches the parser, so the range and path
        // checks are now the only thing between a malformed archive and the reader. A crash
        // here would be reachable from any wallpaper a user imports.
        for seed in UInt64(1) ... 400 {
            var rand = Rand(state: seed)
            var data = Data()
            data.appendLengthPrefixed("PKGV\(String(format: "%04d", rand.int(10000)))")
            for _ in 0 ..< rand.int(512) { data.append(rand.byte()) }

            // The only requirement is that it returns or throws — never traps, never hangs.
            _ = try? PKGArchive(data: data)
        }
    }

    @Test("Truncation at every offset is survivable")
    func fuzzTruncation() {
        // Half-written archives happen: an interrupted copy off a USB drive is the obvious way.
        var builder = PKGBuilder(version: "PKGV0024")
        builder.add("scene.json", #"{"objects":[]}"#)
        builder.add("materials/a.json", #"{"passes":[]}"#)
        let whole = builder.build()

        for cut in 0 ..< whole.count {
            _ = try? PKGArchive(data: whole.prefix(cut))
        }
        // And the untruncated one must still read, so the loop above is not vacuous.
        #expect((try? PKGArchive(data: whole))?.entries.count == 2)
    }

    @Test("A single flipped byte never produces a crash")
    func fuzzBitFlips() {
        var builder = PKGBuilder(version: "PKGV0018")
        builder.add("scene.json", #"{"objects":[]}"#)
        let whole = builder.build()

        for index in 0 ..< min(whole.count, 300) {
            var corrupted = whole
            corrupted[index] = corrupted[index] ^ 0xFF
            _ = try? PKGArchive(data: corrupted)
        }
    }

    @Test("A huge declared entry count is refused rather than allocated")
    func refusesAbsurdCounts() {
        // The reader must not trust entryCount enough to reserve for it.
        for count in [Int32.max, 1_000_000, 65_535] {
            var data = Data()
            data.appendLengthPrefixed("PKGV0024")
            data.appendInt32(count)
            #expect(throws: WEError.self) { try PKGArchive(data: data) }
        }
    }

    @Test("Path traversal is refused at every revision")
    func refusesTraversal() {
        // Accepting more revisions must not mean accepting more paths.
        for version in ["PKGV0001", "PKGV0012", "PKGV0024", "PKGV9999"] {
            for path in ["../../etc/passwd", "/etc/passwd", #"..\..\windows"#, "a/../../b"] {
                var data = Data()
                data.appendLengthPrefixed(version)
                data.appendInt32(1)
                data.appendLengthPrefixed(path)
                data.appendInt32(0)
                data.appendInt32(0)
                #expect(throws: WEError.self, "\(version) accepted \(path)") {
                    try PKGArchive(data: data)
                }
            }
        }
    }
}
