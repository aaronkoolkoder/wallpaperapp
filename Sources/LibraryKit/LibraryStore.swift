import Foundation
import Observation
import os

/// Owns the imported library: where it is, what is in it, and how to get back to it next launch.
///
/// Uses security-scoped bookmarks from the very first version even though Stage 1 ships outside
/// the App Store and does not strictly need them. Retrofitting sandbox-safe file access onto a
/// finished Mac app is weeks of misery, and doing it now costs almost nothing (PLAN.md §10.1).
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
    private let defaults: UserDefaults
    private let scanner = LibraryScanner()
    private let log = Logger(subsystem: "app.diorama", category: "library")

    private static let bookmarkKey = "libraryBookmark"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Import

    /// Adopt a folder the user picked and index it.
    public func importLibrary(at url: URL) {
        releaseScope()
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: Self.bookmarkKey)
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

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            beginAccess(url)
            rootURL = url
            accessError = nil

            // A stale bookmark still resolves but will not survive another launch; refresh it
            // quietly rather than waiting for it to fail.
            if isStale { importLibrary(at: url) } else { rescan() }
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

    public func item(withID id: String) -> WallpaperItem? {
        items.first { $0.id == id }
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
