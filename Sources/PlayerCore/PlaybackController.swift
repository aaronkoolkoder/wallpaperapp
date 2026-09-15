import AppKit
import CoreGraphics
import Diagnostics
import Foundation
import LibraryKit
import WEFormat
import WallpaperKit
import os

/// Chooses a backend for each wallpaper and keeps one playing per display.
///
/// Owns the mapping from display to backend, and is the single place that translates a power
/// directive into "pause this player". Backends never talk to the policy themselves.
@MainActor
public final class PlaybackController {
    private let coordinator: DisplayCoordinator
    private var backends: [CGDirectDisplayID: any WallpaperBackend] = [:]
    private var assignments: [CGDirectDisplayID: WallpaperItem] = [:]
    private let log = Logger(subsystem: "app.diorama", category: "playback")
    private let desktopPicture = DesktopPictureSync()

    /// Whether to hand the system a still of the current wallpaper.
    ///
    /// On by default because without it the menu bar and Mission Control keep tinting for the
    /// user's previous wallpaper, which reads as a rendering bug.
    public var syncsDesktopPicture = true

    /// Fired after a wallpaper starts or fails, carrying the compatibility verdict.
    public var onReport: ((CGDirectDisplayID, CompatibilityReport) -> Void)?

    public init(coordinator: DisplayCoordinator) {
        self.coordinator = coordinator
    }

    public func currentItem(for display: CGDirectDisplayID) -> WallpaperItem? {
        assignments[display]
    }

    public var assignedDisplays: [CGDirectDisplayID] { Array(assignments.keys) }

    /// Start `item` on `display`, replacing whatever was there.
    @discardableResult
    public func play(_ item: WallpaperItem, on display: CGDirectDisplayID) -> CompatibilityReport {
        var report = CompatibilityReport(wallpaperID: item.id)

        guard let surface = coordinator.surfaces[display] else {
            report.add(.unsupported, feature: "Display", detail: "that display is no longer connected")
            return report
        }
        if let unplayable = item.unplayableReason {
            report.add(.unsupported, feature: "Content", detail: unplayable)
            onReport?(display, report)
            return report
        }
        guard let contentURL = item.contentURL else {
            report.add(
                .unsupported, feature: "Content",
                detail: "this wallpaper has no playable content file"
            )
            onReport?(display, report)
            return report
        }

        stop(on: display)

        // Resolve what we will actually play, which is not always what the manifest asked for.
        let resolved = Self.resolvePlayback(for: item, contentURL: contentURL)
        guard let backend = Self.makeBackend(for: resolved.kind) else {
            report.add(
                .unsupported, feature: resolved.kind.displayName + " wallpapers",
                detail: "not supported yet"
            )
            onReport?(display, report)
            return report
        }
        for finding in resolved.findings { report.add(finding) }

        let request = WallpaperRequest(
            id: item.id,
            kind: resolved.kind,
            contentURL: resolved.url,
            baseURL: item.directory
        )

        surface.needsDisplayLink = type(of: backend).needsDisplayLink

        do {
            try backend.start(request, on: surface)
            backends[display] = backend
            assignments[display] = item
            coordinator.setHasContent(true, frameRate: backend.contentFrameRate, for: display)

            // Apply the current directive immediately: if the display is already covered, the
            // wallpaper should start paused rather than render one pointless frame.
            let directive = coordinator.policy.directive(for: display)
            backend.setPaused(directive.isSuspended)

            // Preserve findings recorded during resolution; the backend's own report starts empty.
            for finding in backend.report.findings { report.add(finding) }

            if syncsDesktopPicture {
                desktopPicture.sync(to: resolved.url, wallpaperID: item.id)
            }
            log.info("display \(display): playing \(item.title, privacy: .public)")
        } catch {
            report.add(.unsupported, feature: "Playback", detail: error.localizedDescription)
            log.error("display \(display): \(error.localizedDescription, privacy: .public)")
        }

        onReport?(display, report)
        return report
    }

    public func stop(on display: CGDirectDisplayID) {
        backends[display]?.stop()
        backends.removeValue(forKey: display)
        assignments.removeValue(forKey: display)
        coordinator.surfaces[display]?.needsDisplayLink = true
        coordinator.surfaces[display]?.unmountContent()
        coordinator.setHasContent(false, for: display)
    }

    public func stopAll() {
        for display in Array(backends.keys) { stop(on: display) }
        // Give the user their own wallpaper back rather than leaving ours behind after quit.
        desktopPicture.restoreOriginal()
    }

    /// Relay a power decision to the backend. Called from the coordinator's directive callback.
    public func applyDirective(_ directive: RenderDirective, to display: CGDirectDisplayID) {
        backends[display]?.setPaused(directive.isSuspended)
    }

    // MARK: - Backend selection

    struct ResolvedPlayback {
        var kind: WallpaperKind
        var url: URL
        var findings: [CompatibilityFinding] = []
    }

    /// Decide what to actually play.
    ///
    /// Scene wallpapers have no renderer yet (that is M4 through M6), so they degrade to their
    /// own preview image rather than showing black. A still frame of the wallpaper you asked for
    /// is a much better failure than nothing, it keeps the library usable while the scene engine
    /// is built, and the compatibility report says plainly that this is what happened.
    static func resolvePlayback(for item: WallpaperItem, contentURL: URL) -> ResolvedPlayback {
        let kind: WallpaperKind = switch item.type {
        case .video: .video
        case .web: .web
        case .scene: .scene
        case .application: .application
        case .unknown: Self.kindFromExtension(contentURL)
        }

        if kind == .scene {
            guard let preview = item.previewURL else {
                return ResolvedPlayback(kind: .scene, url: contentURL)
            }
            return ResolvedPlayback(
                kind: .image,
                url: preview,
                findings: [CompatibilityFinding(
                    level: .degraded,
                    feature: "Scene rendering",
                    detail: "showing this wallpaper's preview image for now; "
                        + "animated scenes are not supported yet"
                )]
            )
        }
        return ResolvedPlayback(kind: kind, url: contentURL)
    }

    static func kindFromExtension(_ url: URL) -> WallpaperKind {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "webm", "mkv", "avi": .video
        case "html", "htm": .web
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp": .image
        case "pkg": .scene
        default: .application
        }
    }

    static func makeBackend(for kind: WallpaperKind) -> (any WallpaperBackend)? {
        switch kind {
        case .video: VideoBackend()
        case .web: WebBackend()
        case .image: ImageBackend()
        // Not yet implemented — M4 through M6.
        case .scene, .application: nil
        }
    }
}
