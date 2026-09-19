import Foundation
import Testing
@testable import LibraryKit

/// The import-then-relaunch path: the folder a user picked has to still be there next time.
@Suite("LibraryStore bookmarks")
@MainActor
struct LibraryStoreBookmarkTests {

    /// Fresh storage per test, in memory.
    ///
    /// Never a real `UserDefaults` suite: that writes a plist into the user's home directory,
    /// and deleting it afterwards races with `cfprefsd` writing it back, so a parallel test run
    /// leaves strays behind however carefully it tidies up.
    private func withDefaults(_ body: (any PreferenceStorage) throws -> Void) rethrows {
        try body(InMemoryPreferences())
    }

    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaLib-\(UUID().uuidString)", isDirectory: true)
        let item = root.appendingPathComponent("123456", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try #"{"title":"One","type":"scene","file":"scene.json","tags":[]}"#.write(
            to: item.appendingPathComponent("project.json"), atomically: true, encoding: .utf8
        )
        try #"{"objects":[]}"#.write(
            to: item.appendingPathComponent("scene.json"), atomically: true, encoding: .utf8
        )
        return root
    }

    @Test("A library imported in one launch reopens in the next")
    func importThenRestore() throws {
        // The happy path, which a unit test can check. What it cannot check is the failure it
        // was written for — see `unsandboxedBuildsWritePlainBookmarks`.
        try withDefaults { defaults in
            let root = try makeLibrary()
            defer { try? FileManager.default.removeItem(at: root) }

            let first = LibraryStore(defaults: defaults)
            first.importLibrary(at: root)
            #expect(first.rootURL == root)
            #expect(first.accessError == nil)

            // A separate store over the same preferences is what the next launch looks like.
            let second = LibraryStore(defaults: defaults)
            second.restore()

            #expect(second.accessError == nil, "the folder was reported as lost on reopen")
            #expect(second.rootURL?.standardizedFileURL == root.standardizedFileURL)
        }
    }

    @Test("An unsandboxed build does not write security-scoped bookmarks")
    func unsandboxedBuildsWritePlainBookmarks() {
        // This pins the decision, because the failure it prevents cannot be reproduced inside a
        // single test process.
        //
        // A security-scoped bookmark is bound to the creating app's designated requirement.
        // Ad-hoc signing — what Stage 1 ships — makes that requirement the binary's own hash, so
        // it changes on every build and every bookmark the previous build wrote then fails with
        // NSCocoaErrorDomain 259. A test binary resolves its own bookmarks happily whichever
        // form they take, so it cannot see this; it takes two differently-signed binaries.
        //
        // Verified that way once, by hand: two ad-hoc-signed helpers with different cdhashes,
        // where the scoped bookmark failed with 259 and the plain one resolved.
        guard !LibraryStore.isSandboxed else { return }
        #expect(LibraryStore.bookmarkCreationOptions.isEmpty)
    }

    @Test("A sandboxed build would write security-scoped bookmarks")
    func sandboxedBuildsWouldScope() {
        // The other half of the same decision: Stage 2 has the entitlement and a stable
        // Developer ID signature, where a scoped bookmark is both required and durable.
        guard LibraryStore.isSandboxed else { return }
        #expect(LibraryStore.bookmarkCreationOptions.contains(.withSecurityScope))
    }

    @Test("A bookmark round-trips through the form this build can write")
    func bookmarkRoundTrip() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let bookmark = try LibraryStore.makeBookmark(for: root)
        let resolved = try LibraryStore.resolveBookmark(bookmark)
        #expect(resolved.url.standardizedFileURL == root.standardizedFileURL)
    }

    @Test("A bookmark written by a build with different sandboxing still resolves")
    func resolvesTheOtherForm() throws {
        // The stored data outlives the build that wrote it. A library imported by Stage 1
        // outside the sandbox must still open in the sandboxed App Store build, and vice versa.
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let otherForm: URL.BookmarkCreationOptions =
            LibraryStore.isSandboxed ? [] : [.withSecurityScope]
        let bookmark = try root.bookmarkData(
            options: otherForm, includingResourceValuesForKeys: nil, relativeTo: nil
        )

        let resolved = try LibraryStore.resolveBookmark(bookmark)
        #expect(resolved.url.standardizedFileURL == root.standardizedFileURL)
    }

    @Test("Nothing stored means no error, just no library")
    func noBookmarkIsNotAnError() throws {
        // A first launch must not look like a failure.
        try withDefaults { defaults in
            let store = LibraryStore(defaults: defaults)
            store.restore()
            #expect(store.rootURL == nil)
            #expect(store.accessError == nil)
        }
    }

    @Test("A bookmark pointing at a folder that is gone reports it")
    func missingFolderReports() throws {
        try withDefaults { defaults in
            let root = try makeLibrary()
            let store = LibraryStore(defaults: defaults)
            store.importLibrary(at: root)
            try FileManager.default.removeItem(at: root)

            let reopened = LibraryStore(defaults: defaults)
            reopened.restore()
            #expect(reopened.accessError != nil)
        }
    }

    @Test("Forgetting a library clears what was stored")
    func forgetClearsBookmark() throws {
        try withDefaults { defaults in
            let root = try makeLibrary()
            defer { try? FileManager.default.removeItem(at: root) }

            let store = LibraryStore(defaults: defaults)
            store.importLibrary(at: root)
            store.forgetLibrary()

            #expect(defaults.data(forKey: "libraryBookmark") == nil)
            let reopened = LibraryStore(defaults: defaults)
            reopened.restore()
            #expect(reopened.rootURL == nil)
        }
    }
}
