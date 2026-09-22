import AppKit
import Diagnostics
import LibraryKit
import Observation
import PlayerCore
import SceneEngine
import WEFormat
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
            if persistsPreferences { PowerPreferencesStorage.save(preferences) }
            refresh()
        }
    }

    /// False while a diagnostic override is in force, so what it sets is never saved as though
    /// the user had chosen it.
    var persistsPreferences = true

    let library: LibraryStore

    /// Audio reactivity is off until asked for. Turning it on is what triggers the Screen
    /// Recording prompt, so it must never happen as a side effect of anything else.
    var audioReactivityEnabled: Bool {
        didSet {
            guard audioReactivityEnabled != oldValue else { return }
            UserDefaults.standard.set(audioReactivityEnabled, forKey: "audioReactivity")
            if audioReactivityEnabled {
                Task { await audioCapture.start() }
            } else {
                audioCapture.stop()
            }
        }
    }

    private(set) var audioStatus: SystemAudioCapture.Status = .idle
    let audioCapture = SystemAudioCapture()

    private let coordinator: DisplayCoordinator
    private let playback: PlaybackController
    private var reports: [CGDirectDisplayID: CompatibilityReport] = [:]

    init(coordinator: DisplayCoordinator, playback: PlaybackController, library: LibraryStore) {
        self.coordinator = coordinator
        self.playback = playback
        self.library = library
        // The energy settings as the user left them. They used to start from the defaults on
        // every launch, so switching off "Stop under fullscreen apps" lasted until the next one.
        let saved = PowerPreferencesStorage.load()
        self.preferences = saved
        coordinator.setPreferences(saved)
        self.audioReactivityEnabled = UserDefaults.standard.bool(forKey: "audioReactivity")

        audioCapture.onStatusChange = { [weak self] status in
            self?.audioStatus = status
        }
        if audioReactivityEnabled {
            Task { [audioCapture] in await audioCapture.start() }
        }

        playback.onReport = { [weak self] displayID, report in
            self?.reports[displayID] = report
            self?.refresh()
        }

        // Connect captured audio to whatever is playing. Until now the capture ran, asked for
        // a permission, and threw every frame away: `audioSource` was declared on the scene
        // backend and never assigned by anybody, so audio reactivity did nothing at all.
        playback.audioSource = { [audioCapture] in
            MainActor.assumeIsolated { audioCapture.currentFrame() }
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

    /// Displays a wallpaper can be sent to, main first.
    var displayTargets: [(id: CGDirectDisplayID, name: String)] {
        displays.map { (id: $0.id, name: $0.name) }
    }

    func isPlaying(_ wallpaperID: String, on displayID: CGDirectDisplayID? = nil) -> Bool {
        guard let displayID else {
            return displays.contains { $0.wallpaperID == wallpaperID }
        }
        return displays.first { $0.id == displayID }?.wallpaperID == wallpaperID
    }

    func clear(_ displayID: CGDirectDisplayID) {
        playback.stop(on: displayID)
        refresh()
    }

    func item(withID id: String) -> WallpaperItem? { library.item(withID: id) }


    // MARK: - Wallpaper settings

    /// The user's changed settings, mirrored from the store so SwiftUI can observe them.
    ///
    /// The store itself is plain persistence and not observable; keeping a mirror here is what
    /// lets a slider redraw without the model rebuilding its whole display snapshot, which
    /// mid-drag would rewrite the entire UI.
    private(set) var propertyOverridesByWallpaper: [String: [String: DynamicValue]] = [:]

    /// Reads through to the store the first time a wallpaper is asked about, so settings saved
    /// in an earlier session show up without loading the whole store at launch.
    func propertyOverrides(for wallpaperID: String) -> [String: DynamicValue] {
        if let known = propertyOverridesByWallpaper[wallpaperID] { return known }
        return playback.propertySettings.properties(for: wallpaperID)
    }

    /// Change one setting. Takes effect on the next frame wherever the wallpaper is showing.
    ///
    /// - Parameter value: nil restores whatever the wallpaper's author shipped.
    func setProperty(_ value: DynamicValue?, named key: String, on wallpaperID: String) {
        playback.setProperty(value, named: key, on: wallpaperID)
        propertyOverridesByWallpaper[wallpaperID] = playback.propertySettings.properties(for: wallpaperID)
    }

    func resetProperties(on wallpaperID: String) {
        playback.resetProperties(on: wallpaperID)
        propertyOverridesByWallpaper[wallpaperID] = [:]
    }

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

/// Where the energy settings live between launches: one JSON value in the app's preferences,
/// decoded over the defaults so an option added later starts at its default instead of
/// discarding everything the user had set.
enum PowerPreferencesStorage {
    static let key = "powerPreferences"

    static func load(from defaults: UserDefaults = .standard) -> PowerPreferences {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(PowerPreferences.self, from: data)
        else { return .default }
        return saved
    }

    static func save(_ preferences: PowerPreferences, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
