import Foundation
import WEFormat

/// One wallpaper in the library, as indexed from disk.
public struct WallpaperItem: Sendable, Identifiable, Hashable {
    /// The Workshop item ID — the numeric directory name. Stable across machines, which makes it
    /// the right key for per-wallpaper settings and caches.
    public let id: String
    public let title: String
    public let type: WallpaperType
    /// Directory containing `project.json`.
    public let directory: URL
    /// Absolute URL of the entry point named by the manifest, when it exists on disk.
    public let contentURL: URL?
    public let previewURL: URL?
    public let tags: [String]
    public let contentRating: String?
    /// User-configurable properties declared by the wallpaper itself.
    public let properties: [String: WEProperty]
    public let sizeBytes: Int64
    public let modifiedAt: Date?

    /// Why this item cannot be played, if it cannot. Populated at scan time so the library can
    /// show the reason in place rather than silently omitting the item — a user who moved 300
    /// wallpapers across and sees 280 needs to know what happened to the other 20.
    public let unplayableReason: String?

    public var isPlayable: Bool { unplayableReason == nil }

    public init(
        id: String, title: String, type: WallpaperType, directory: URL,
        contentURL: URL?, previewURL: URL?, tags: [String], contentRating: String?,
        properties: [String: WEProperty], sizeBytes: Int64, modifiedAt: Date?,
        unplayableReason: String?
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.directory = directory
        self.contentURL = contentURL
        self.previewURL = previewURL
        self.tags = tags
        self.contentRating = contentRating
        self.properties = properties
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.unplayableReason = unplayableReason
    }
}

/// What a scan found, including what it could not read.
public struct ScanResult: Sendable {
    public var items: [WallpaperItem]
    /// Directories that looked like wallpapers but could not be indexed, with the reason.
    public var failures: [(directory: String, reason: String)]
    public var scannedDirectories: Int
    public var duration: TimeInterval

    public init(
        items: [WallpaperItem] = [], failures: [(directory: String, reason: String)] = [],
        scannedDirectories: Int = 0, duration: TimeInterval = 0
    ) {
        self.items = items
        self.failures = failures
        self.scannedDirectories = scannedDirectories
        self.duration = duration
    }

    public var playableCount: Int { items.filter(\.isPlayable).count }
}
