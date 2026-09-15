import AppKit
import Diagnostics
import Foundation
import WallpaperKit

/// What kind of content a backend plays.
public enum WallpaperKind: String, Sendable, Codable, CaseIterable {
    case scene
    case video
    case web
    case image

    /// Wallpaper Engine's fourth type is a Windows executable. It is permanently out of scope,
    /// but it is modelled explicitly so the library can say so plainly rather than silently
    /// dropping those items and leaving the user wondering where a wallpaper went.
    case application

    public var isSupported: Bool { self != .application }

    public var displayName: String {
        switch self {
        case .scene: "Scene"
        case .video: "Video"
        case .web: "Web"
        case .image: "Image"
        case .application: "Application"
        }
    }
}

/// Everything a backend needs to start playing.
public struct WallpaperRequest: Sendable {
    /// Stable identifier, typically the Workshop item ID.
    public let id: String
    public let kind: WallpaperKind
    /// The primary content file, already resolved to an absolute path.
    public let contentURL: URL
    /// The directory the wallpaper lives in, for resolving relative references.
    public let baseURL: URL
    /// Whether the content should loop. Effectively always true for wallpapers.
    public let loops: Bool
    /// Wallpapers are silent by default — a background image that makes noise is a bug, not a
    /// feature, and this is the single most common complaint about live wallpaper apps.
    public let isMuted: Bool

    public init(
        id: String, kind: WallpaperKind, contentURL: URL, baseURL: URL,
        loops: Bool = true, isMuted: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.contentURL = contentURL
        self.baseURL = baseURL
        self.loops = loops
        self.isMuted = isMuted
    }
}

/// A player for one kind of wallpaper, bound to one surface.
///
/// Backends are deliberately *not* required to render through Metal. A video wallpaper is best
/// served by handing compressed frames straight to `AVSampleBufferDisplayLayer` so decode stays
/// in the fixed-function block, and a web wallpaper needs a live `WKWebView`. Forcing either
/// through a Metal render graph would mean a texture copy per frame for no benefit.
@MainActor
public protocol WallpaperBackend: AnyObject {
    static var kind: WallpaperKind { get }

    /// The content's own frame rate, when it declares one. Feeds the power policy so we never
    /// render faster than the content actually changes.
    var contentFrameRate: Int? { get }

    /// Findings accumulated while loading — what could not be rendered and why.
    var report: CompatibilityReport { get }

    /// Mount onto a surface and begin playing.
    func start(_ request: WallpaperRequest, on surface: DesktopSurface) throws

    /// Stop and release everything. Must be safe to call more than once.
    func stop()

    /// Suspend or resume without tearing down. Called when the power policy flips.
    func setPaused(_ paused: Bool)
}

public enum BackendError: Error, LocalizedError {
    case unsupportedKind(WallpaperKind)
    case contentMissing(URL)
    case contentUnreadable(URL, underlying: String)
    case noRenderableTrack

    public var errorDescription: String? {
        switch self {
        case .unsupportedKind(let kind):
            "\(kind.displayName) wallpapers are not supported"
        case .contentMissing(let url):
            "The file \(url.lastPathComponent) is missing"
        case .contentUnreadable(let url, let underlying):
            "Could not read \(url.lastPathComponent): \(underlying)"
        case .noRenderableTrack:
            "The video contains no playable video track"
        }
    }
}
