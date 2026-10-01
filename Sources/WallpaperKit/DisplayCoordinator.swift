import AppKit
import CoreGraphics
import os

/// Owns the set of ``DesktopSurface``s and keeps it in step with the display topology.
///
/// Screen changes are handled as a full teardown and rebuild rather than an incremental diff.
/// Display topology changes are rare (a cable, a resolution change, a dock), and diffing them
/// correctly across mirroring, arrangement changes and scale-factor changes is a well-known
/// source of subtle bugs. Rebuilding is cheap here because a surface owns almost nothing.
@MainActor
public final class DisplayCoordinator {
    public private(set) var surfaces: [CGDirectDisplayID: DesktopSurface] = [:]

    public let policy: PowerPolicy
    private let monitor = SystemPowerMonitor()
    private var screenObserver: (any NSObjectProtocol)?
    private var fullscreenPollTimer: Timer?
    private let log = Logger(subsystem: "app.diorama", category: "displays")

    /// Called when a surface is created, so the owner can attach a renderer to it.
    public var onSurfaceAdded: ((DesktopSurface) -> Void)?
    /// Called before a surface goes away, so the owner can release GPU resources.
    public var onSurfaceRemoved: ((CGDirectDisplayID) -> Void)?

    public init(preferences: PowerPreferences = .default) {
        policy = PowerPolicy(preferences: preferences)
    }

    public func start() {
        monitor.onChange = { [weak self] state in
            self?.policy.systemStateChanged(state)
        }
        monitor.start()
        policy.systemStateChanged(monitor.state)

        policy.onDirectiveChange = { [weak self] displayID, directive in
            self?.surfaces[displayID]?.apply(directive)
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildSurfaces() }
        }

        rebuildSurfaces()
        startFullscreenPolling()
    }

    public func stop() {
        monitor.stop()
        fullscreenPollTimer?.invalidate()
        fullscreenPollTimer = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        for (displayID, surface) in surfaces {
            onSurfaceRemoved?(displayID)
            surface.tearDown()
        }
        surfaces.removeAll()
    }

    /// Declare whether a display currently has something to render. Drives the `.noContent`
    /// suspension case.
    public func setHasContent(_ hasContent: Bool, frameRate: Int? = nil, for displayID: CGDirectDisplayID) {
        var conditions = currentConditions(for: displayID)
        conditions.hasContent = hasContent
        conditions.contentFrameRate = frameRate
        policy.updateConditions(conditions, for: displayID)
    }

    public func setPreferences(_ preferences: PowerPreferences) {
        policy.preferences = preferences
        for surface in surfaces.values {
            surface.setResolutionScale(preferences.resolutionScale)
        }
    }

    // MARK: - Topology

    private func rebuildSurfaces() {
        let live = Self.displayMap()
        log.info("rebuilding surfaces for \(live.count) display(s)")

        // Drop surfaces for displays that went away.
        for (displayID, surface) in surfaces where live[displayID] == nil {
            onSurfaceRemoved?(displayID)
            surface.tearDown()
            surfaces.removeValue(forKey: displayID)
            policy.removeDisplay(displayID)
        }

        for (displayID, screen) in live {
            if let existing = surfaces[displayID] {
                existing.update(screen: screen)
            } else {
                let surface = DesktopSurface(screen: screen, displayID: displayID)
                surface.setResolutionScale(policy.preferences.resolutionScale)
                surface.onOcclusionChange = { [weak self] occluded in
                    guard let self else { return }
                    var conditions = self.currentConditions(for: displayID)
                    conditions.isOccluded = occluded
                    self.policy.updateConditions(conditions, for: displayID)
                }
                surfaces[displayID] = surface

                // Seed conditions BEFORE notifying the owner. The callback typically calls
                // `setHasContent`, and pushing a fresh `DisplayConditions` afterwards would
                // clobber it back to `.noContent`.
                var conditions = DisplayConditions()
                conditions.isOccluded = surface.isOccluded
                policy.updateConditions(conditions, for: displayID)

                surface.show()
                onSurfaceAdded?(surface)
            }
        }
    }

    /// `NSScreen` and `CGDirectDisplayID` are related only through this device-description key.
    private static func displayMap() -> [CGDirectDisplayID: NSScreen] {
        var map: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { continue }
            map[CGDirectDisplayID(number.uint32Value)] = screen
        }
        return map
    }

    private func currentConditions(for displayID: CGDirectDisplayID) -> DisplayConditions {
        var conditions = DisplayConditions()
        if let surface = surfaces[displayID] {
            conditions.isOccluded = surface.isOccluded
        }
        // Preserve fields the caller is not currently updating.
        if let existing = policy.existingConditions(for: displayID) {
            conditions.hasContent = existing.hasContent
            conditions.contentFrameRate = existing.contentFrameRate
            conditions.isCoveredByFullscreenApp = existing.isCoveredByFullscreenApp
        }
        return conditions
    }

    // MARK: - Fullscreen

    /// There is no notification for "a fullscreen app now covers this display", so this is
    /// polled. It is deliberately slow (2s).
    ///
    /// It re-reads occlusion as well, which has a notification but is the one condition where
    /// missing a change is unrecoverable: a wallpaper suspended because the desktop was covered
    /// stays suspended, showing its last frame, and from the outside looks exactly like a
    /// wallpaper that does not animate. Everything else resumes on some other event eventually.
    /// Two seconds of latency uncovering the desktop is not noticeable; never resuming is.
    private func startFullscreenPolling() {
        fullscreenPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFullscreen() }
        }
        fullscreenPollTimer?.tolerance = 0.5
    }

    private func pollFullscreen() {
        // Keep polling while anything is suspended, not only while something is running:
        // otherwise nothing would ever notice the fullscreen app being dismissed or the
        // desktop being uncovered, which are the two things this exists to catch.
        let anyPlaying = policy.allDisplays.contains {
            policy.existingConditions(for: $0)?.hasContent == true
        }
        guard anyPlaying else { return }

        for (displayID, surface) in surfaces {
            let covered = FullscreenDetector.isDisplayCovered(surface.screen)
            // `currentConditions` re-reads the surface's occlusion, so this picks up a missed
            // `didChangeOcclusionState` as well as a dismissed fullscreen app.
            var conditions = currentConditions(for: displayID)
            let known = policy.existingConditions(for: displayID)
            guard conditions.isCoveredByFullscreenApp != covered
                || known?.isOccluded != conditions.isOccluded
            else { continue }
            conditions.isCoveredByFullscreenApp = covered
            policy.updateConditions(conditions, for: displayID)
        }
    }
}
