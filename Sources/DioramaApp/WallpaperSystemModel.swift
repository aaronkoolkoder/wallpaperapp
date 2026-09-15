import AppKit
import Diagnostics
import LibraryKit
import Observation
import PlayerCore
import WallpaperKit

/// A display as the UI needs to see it.
struct DisplaySnapshot: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isMain: Bool
    let resolution: CGSize
    var wallpaperTitle: String?
    var wallpaperID: String?
    var previewURL: URL?
    var directive: RenderDirective
    var report: CompatibilityReport?

    var statusText: String {
        switch directive {
        case .running(let fps): "Playing · \(fps) fps"
        case .suspended(let reason): reason.description
        }
    }

    var isRunning: Bool { !directive.isSuspended }

    /// Compares only what the UI draws. `CompatibilityReport` carries findings that are not
    /// themselves comparable, and a report changing does not by itself change this row.
    static func == (lhs: DisplaySnapshot, rhs: DisplaySnapshot) -> Bool {
        lhs.id == rhs.id
            && lhs.wallpaperID == rhs.wallpaperID
            && lhs.directive == rhs.directive
            && lhs.name == rhs.name
            && lhs.report?.level == rhs.report?.level
    }
}

/// Bridges the running wallpaper system into something SwiftUI can observe.
///
/// The system itself is built from AppKit and Metal objects that are not observable, so this
/// pulls a snapshot rather than trying to make the whole engine `@Observable`. Snapshots are
/// refreshed on demand — while the menu is open, or when something actually changes — rather
/// than on a timer, because a background app polling once a second to describe how little work
/// it is doing would be its own small betrayal of the point.
@MainActor
@Observable
final class WallpaperSystemModel {
    private(set) var displays: [DisplaySnapshot] = []
    private(set) var isPaused = false
    private(set) var systemState = SystemState()

    var preferences: PowerPreferences {
        didSet {
            guard preferences != oldValue else { return }
            coordinator.setPreferences(preferences)
            refresh()
        }
    }

    let library: LibraryStore

    private let coordinator: DisplayCoordinator
    private let playback: PlaybackController
    private var reports: [CGDirectDisplayID: CompatibilityReport] = [:]

    init(coordinator: DisplayCoordinator, playback: PlaybackController, library: LibraryStore) {
        self.coordinator = coordinator
        self.playback = playback
        self.library = library
        self.preferences = coordinator.policy.preferences

        playback.onReport = { [weak self] displayID, report in
            self?.reports[displayID] = report
            self?.refresh()
        }
    }

    // MARK: - Snapshot

    func refresh() {
        // Offscreen interface rendering injects fixed data; refreshing would immediately
        // replace it with the real (empty) state and defeat the preview.
        guard !isPreview else { return }
        isPaused = coordinator.policy.isUserPaused
        systemState = coordinator.policy.systemState

        displays = coordinator.surfaces
            .map { displayID, surface in
                let item = playback.currentItem(for: displayID)
                return DisplaySnapshot(
                    id: displayID,
                    name: Self.name(for: surface.screen),
                    isMain: surface.screen == NSScreen.main,
                    resolution: surface.screen.frame.size,
                    wallpaperTitle: item?.title,
                    wallpaperID: item?.id,
                    previewURL: item?.previewURL,
                    directive: surface.directive,
                    report: reports[displayID]
                )
            }
            // Main display first, then a stable order so the list does not reshuffle between
            // refreshes and make the popover feel jittery.
            .sorted { lhs, rhs in
                if lhs.isMain != rhs.isMain { return lhs.isMain }
                return lhs.id < rhs.id
            }
    }

    private static func name(for screen: NSScreen) -> String {
        let name = screen.localizedName
        return name.isEmpty ? "Display" : name
    }

    // MARK: - Actions

    func togglePause() {
        coordinator.policy.isUserPaused.toggle()
        refresh()
    }

    func play(_ item: WallpaperItem, on displayID: CGDirectDisplayID? = nil) {
        let targets = displayID.map { [$0] } ?? Array(coordinator.surfaces.keys)
        for target in targets { _ = playback.play(item, on: target) }
        refresh()
    }

    func clear(_ displayID: CGDirectDisplayID) {
        playback.stop(on: displayID)
        refresh()
    }

    func item(withID id: String) -> WallpaperItem? { library.item(withID: id) }

    private var isPreview = false

    /// Fixed system state for offscreen interface rendering.
    func injectPreviewState(_ state: SystemState) {
        systemState = state
        isPreview = true
    }

    /// Replace the snapshot with fixed data, for offscreen interface rendering only.
    func injectPreviewDisplays(_ snapshots: [DisplaySnapshot]) {
        displays = snapshots
        isPreview = true
    }

    // MARK: - Derived

    var activeCount: Int { displays.filter(\.isRunning).count }

    /// One line summarising why nothing is drawing, when nothing is.
    var idleReason: String? {
        guard activeCount == 0, let first = displays.first else { return nil }
        if case .suspended(let reason) = first.directive { return reason.description }
        return nil
    }

    /// Plain-language energy note.
    ///
    /// Deliberately describes behaviour rather than quoting a CPU percentage. A number without
    /// context invites comparison against whatever Activity Monitor happens to show, and the
    /// honest story here is about *when* we render, not how fast.
    var energySummary: String {
        if activeCount == 0 { return "Idle — using no energy" }
        if systemState.isLowPowerMode { return "Low Power Mode — reduced frame rate" }
        if !systemState.isOnACPower {
            return "On battery — \(preferences.frameRateOnBattery) fps"
        }
        return "Plugged in — \(preferences.frameRateOnAC) fps"
    }

    var thermalWarning: String? {
        switch systemState.thermalState {
        case .serious: "Your Mac is warm — frame rate reduced"
        case .critical: "Your Mac is too warm — wallpapers paused"
        default: nil
        }
    }
}
