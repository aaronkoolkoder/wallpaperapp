import AppKit
import CoreGraphics
import Diagnostics
import Foundation
import LibraryKit
import SceneEngine
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
    public var syncsDesktopPicture =
        ProcessInfo.processInfo.environment["DIORAMA_NO_DESKTOP_SYNC"] != "1"


    /// What was playing where, so a launch can put it back.
    public let session: WallpaperSessionStore

    /// The user's per-wallpaper settings, remembered across launches.
    public let propertySettings: PropertySettingsStore

    /// Change one of a wallpaper's settings, applying it to anything currently showing it.
    ///
    /// Takes effect on the next frame rather than restarting the wallpaper: restarting would
    /// recompile its shaders and reload its textures to change one float, and would flash every
    /// time a slider moved.
    ///
    /// - Parameter value: nil restores whatever the wallpaper's author shipped.
    public func setProperty(_ value: DynamicValue?, named property: String, on wallpaperID: String) {
        propertySettings.set(value, for: property, on: wallpaperID)
        applyProperties(of: wallpaperID)
    }

    /// Restore every setting on a wallpaper to the author's values.
    public func resetProperties(on wallpaperID: String) {
        propertySettings.reset(wallpaperID)
        applyProperties(of: wallpaperID)
    }

    /// Pushes the stored settings to every display showing that wallpaper.
    ///
    /// A wallpaper can be on more than one display at once, and changing a setting on one of
    /// them and not the others would look like a bug rather than a feature.
    private func applyProperties(of wallpaperID: String) {
        let properties = propertySettings.properties(for: wallpaperID)
        for (display, item) in assignments where item.id == wallpaperID {
            backends[display]?.applyProperties(properties)
        }
    }

    /// Where backends read analysed system audio from, when the user has turned reactivity on.
    ///
    /// Held here rather than passed at construction because it is toggled while wallpapers are
    /// already playing, and every running backend has to pick the change up.
    public var audioSource: (() -> AudioFrame)? {
        didSet {
            for backend in backends.values { backend.setAudioSource(audioSource) }
        }
    }

    /// Fired after a wallpaper starts or fails, carrying the compatibility verdict.
    public var onReport: ((CGDirectDisplayID, CompatibilityReport) -> Void)?

    public init(
        coordinator: DisplayCoordinator,
        propertySettings: PropertySettingsStore = PropertySettingsStore(),
        session: WallpaperSessionStore = WallpaperSessionStore()
    ) {
        self.coordinator = coordinator
        self.propertySettings = propertySettings
        self.session = session
        // Before anything else: if a previous run died without restoring, give the user their
        // own wallpaper back rather than silently keeping ours.
        desktopPicture.reconcileAfterUngracefulExit()
    }

    /// Frames drawn by whatever is playing on `display`.
    public func framesRendered(on display: CGDirectDisplayID) -> UInt64 {
        backends[display]?.framesRendered ?? 0
    }

    /// Whether the policy currently has `display` suspended, for diagnostics that need to tell
    /// "not animating" apart from "deliberately paused".
    public func isSuspended(on display: CGDirectDisplayID) -> Bool {
        coordinator.policy.directive(for: display).isSuspended
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
            baseURL: item.directory,
            properties: propertySettings.properties(for: item.id),
            // A web wallpaper is handed its declared properties with the user's changes folded
            // in, because its listener expects the whole set rather than a diff.
            webProperties: Self.webProperties(
                declared: item.properties,
                overrides: propertySettings.properties(for: item.id)
            )
        )

        surface.needsDisplayLink = type(of: backend).needsDisplayLink
        backend.setAudioSource(audioSource)

        do {
            try backend.start(request, on: surface)
            backends[display] = backend
            assignments[display] = item
            session.remember(item.id, on: display)
            coordinator.setHasContent(true, frameRate: backend.contentFrameRate, for: display)

            // Apply the current directive immediately: if the display is already covered, the
            // wallpaper should start paused rather than render one pointless frame.
            let directive = coordinator.policy.directive(for: display)
            backend.setPaused(directive.isSuspended)

            // Preserve findings recorded during resolution; the backend's own report starts empty.
            for finding in backend.report.findings { report.add(finding) }

            if syncsDesktopPicture {
                desktopPicture.sync(
                    to: resolved.url, wallpaperID: item.id, previewURL: item.previewURL
                )
            }
            log.info("display \(display): playing \(item.title, privacy: .public)")
        } catch {
            report.add(.unsupported, feature: "Playback", detail: error.localizedDescription)
            log.error("display \(display): \(error.localizedDescription, privacy: .public)")
        }

        onReport?(display, report)
        return report
    }

    /// Clear a display. The user meant it, so the next launch leaves it clear too.
    public func stop(on display: CGDirectDisplayID) {
        session.forget(display)
        tearDown(on: display)
    }

    /// Stop playing without touching what is remembered.
    ///
    /// Quitting is not the same decision as clearing a display: an app that forgot its
    /// wallpapers every time it shut down would come back to a blank desktop, which is the
    /// whole thing the session store exists to prevent.
    private func tearDown(on display: CGDirectDisplayID) {
        backends[display]?.stop()
        backends.removeValue(forKey: display)
        assignments.removeValue(forKey: display)
        coordinator.surfaces[display]?.needsDisplayLink = true
        coordinator.surfaces[display]?.unmountContent()
        coordinator.setHasContent(false, for: display)
    }

    public func stopAll() {
        for display in Array(backends.keys) { tearDown(on: display) }
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
    /// Scenes render natively as of M4. A scene that fails to load still reports why through the
    /// compatibility report rather than silently showing black.
    /// A wallpaper's declared properties with the user's changes applied to their values.
    static func webProperties(
        declared: [String: WEProperty],
        overrides: [String: DynamicValue]
    ) -> [String: WEProperty] {
        guard !overrides.isEmpty else { return declared }
        var merged = declared
        for (key, value) in overrides {
            // Only keys the wallpaper actually declares: inventing one would hand its listener
            // a property it has no code to apply.
            guard var property = merged[key] else { continue }
            property.value = value
            merged[key] = property
        }
        return merged
    }

    static func resolvePlayback(for item: WallpaperItem, contentURL: URL) -> ResolvedPlayback {
        let kind: WallpaperKind = switch item.type {
        case .video: .video
        case .web: .web
        case .scene: .scene
        case .application: .application
        case .unknown: Self.kindFromExtension(contentURL)
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
        case .scene: SceneBackend()
        // Windows executables; permanently out of scope.
        case .application: nil
        }
    }
}
