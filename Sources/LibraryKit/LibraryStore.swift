import Foundation
import Observation
import os

/// Owns the imported library: where it is, what is in it, and how to get back to it next launch.
///
/// Bookmarks the folder so it comes back next launch: security-scoped inside the App Sandbox,
/// plain outside it.
///
/// The distinction is load-bearing, not tidiness. A security-scoped bookmark is bound to the
/// creating app's *designated requirement*, and ad-hoc signing — `codesign --sign -`, which is
/// what Stage 1 ships — makes that requirement the binary's own hash. It therefore changes on
/// every build, and every bookmark the previous build wrote stops resolving with
/// `NSCocoaErrorDomain 259`. The user sees "could not reopen your wallpaper folder" the first
/// time they open a build they just updated to, and has to pick the folder again. A plain
/// bookmark carries no identity and survives the update.
///
/// Resolution accepts either form, so a library imported by Stage 1 still opens once Stage 2 is
/// sandboxed and signed with a stable Developer ID (PLAN.md §10.1).
@MainActor
@Observable
public final class LibraryStore {
    public private(set) var items: [WallpaperItem] = []
    public private(set) var rootURL: URL?
    public private(set) var lastScan: ScanResult?
    public private(set) var isScanning = false

    /// Set when the stored bookmark could not be resolved — usually because the folder moved or
    /// the external drive holding it is not mounted.
    public private(set) var accessError: String?

    private var activeScope: URL?
    private let defaults: any PreferenceStorage
    private let scanner = LibraryScanner()
    private let log = Logger(subsystem: "app.diorama", category: "library")

    private static let bookmarkKey = "libraryBookmark"

    public init(defaults: any PreferenceStorage = UserDefaults.standard) {
        self.defaults = defaults
    }

    // MARK: - Import

    /// Adopt a folder the user picked and index it.
    public func importLibrary(at picked: URL) {
        let url = libraryFolder(for: picked)
        releaseScope()
        do {
            defaults.set(try Self.makeBookmark(for: url), forKey: Self.bookmarkKey)
        } catch {
            // Non-fatal: the library still works this session, it just will not come back
            // automatically next launch.
            log.warning("could not bookmark \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        beginAccess(url)
        rootURL = url
        accessError = nil
        rescan()
    }

    /// Re-adopt the folder from a previous launch.
    public func restore() {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return }

        do {
            let (url, isStale) = try Self.resolveBookmark(bookmark)

            // Rewrite the bookmark rather than use it as it is when either it is stale — it
            // resolves now but will not survive another launch — or it points inside the
            // library rather than at it, which is what an earlier build stored for anyone who
            // picked a single wallpaper's folder.
            if isStale || libraryFolder(for: url).standardizedFileURL != url.standardizedFileURL {
                importLibrary(at: url)
                return
            }

            beginAccess(url)
            rootURL = url
            accessError = nil
            rescan()
        } catch {
            accessError = "Could not reopen your wallpaper folder. It may have moved, "
                + "or the drive it is on may not be connected."
            log.error("bookmark resolution failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func forgetLibrary() {
        releaseScope()
        defaults.removeObject(forKey: Self.bookmarkKey)
        rootURL = nil
        items = []
        lastScan = nil
        accessError = nil
    }

    // MARK: - Scanning

    public func rescan() {
        guard let rootURL else { return }
        isScanning = true

        // Off the main actor: a large library is thousands of file reads and JSON parses, and
        // doing that on the main thread would hang the UI for seconds.
        let scanner = self.scanner
        Task.detached(priority: .userInitiated) {
            let result = scanner.scan(root: rootURL)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastScan = result
                self.items = result.items
                self.isScanning = false
            }
        }
    }

    /// The folder that actually holds the wallpapers, given the one the user picked.
    ///
    /// People pick the Steam folder above the library, or one wallpaper inside it, about as
    /// often as the right one, and the scanner copes with both. Storing the folder *as picked*,
    /// though, made the library's survival hinge on that choice: pick one wallpaper's folder,
    /// later unsubscribe from that wallpaper in Steam, and the whole library fails to reopen —
    /// while the sidebar showed a wallpaper's number where the library's name belonged.
    ///
    /// Inside the sandbox access reaches only what the user picked, so the pick is kept as is.
    func libraryFolder(for picked: URL) -> URL {
        Self.isSandboxed ? picked : scanner.resolveRoot(from: picked)
    }

    public func item(withID id: String) -> WallpaperItem? {
        items.first { $0.id == id }
    }

    // MARK: - Bookmarks

    /// Whether this build is running inside the App Sandbox.
    ///
    /// Only a sandboxed build should write security-scoped bookmarks. Outside the sandbox they
    /// are unnecessary — the app already has the access — and actively harmful, because they
    /// are pinned to a code signature that ad-hoc signing changes on every build.
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// The bookmark options this build can actually honour.
    public static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        isSandboxed ? [.withSecurityScope] : []
    }

    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves a stored bookmark, accepting either kind.
    ///
    /// Both forms are tried rather than assuming, because the stored data outlives the build
    /// that wrote it: a library imported by Stage 1 outside the sandbox has a plain bookmark,
    /// and the sandboxed App Store build in Stage 2 must still be able to reopen it. Preferring
    /// the form this build would write keeps the common path to a single attempt.
    ///
    /// The fallback is also what rescues anyone already holding a scoped bookmark from an
    /// earlier build of Stage 1 — it will not resolve, so the plain attempt is what gets them
    /// their library back instead of an error.
    public static func resolveBookmark(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        let preferred: URL.BookmarkResolutionOptions = isSandboxed ? [.withSecurityScope] : []
        let fallback: URL.BookmarkResolutionOptions = isSandboxed ? [] : [.withSecurityScope]

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark, options: preferred,
                relativeTo: nil, bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        } catch {
            var fallbackStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark, options: fallback,
                relativeTo: nil, bookmarkDataIsStale: &fallbackStale
            )
            // Written by a build with different sandboxing, so it is stale by definition: it
            // must be rewritten in this build's form or the next launch repeats the fallback.
            return (url, true)
        }
    }

    // MARK: - Security scope

    private func beginAccess(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            // Expected when running unsandboxed against a folder we already have access to.
            log.debug("no security scope needed for \(url.path, privacy: .public)")
            return
        }
        activeScope = url
    }

    private func releaseScope() {
        activeScope?.stopAccessingSecurityScopedResource()
        activeScope = nil
    }
}
