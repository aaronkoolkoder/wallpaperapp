import AppKit
import Foundation
import Observation
import os

/// Owns the user's playlists and drives the active one.
///
/// The rotation itself lives in ``PlaylistScheduler``, which is pure. This is the part that has
/// to touch the world: persistence, a timer, and noticing when the system appearance flips.
@MainActor
@Observable
public final class PlaylistStore {
    public private(set) var playlists: [Playlist] = []
    /// The playlist currently rotating, if any.
    public private(set) var activePlaylistID: Playlist.ID?

    /// Called when the rotation picks a wallpaper. The app plays it.
    public var onAdvance: ((String) -> Void)?
    /// Supplied by the app so the scheduler can skip wallpapers that would not render.
    public var isPlayable: ((String) -> Bool)?

    private var states: [Playlist.ID: PlaylistScheduler.State] = [:]
    private let scheduler = PlaylistScheduler()
    private let defaults: UserDefaults
    private var timer: Timer?
    private var appearanceObserver: (any NSObjectProtocol)?
    private var lastAppearanceWasDark: Bool
    private let log = Logger(subsystem: "app.diorama", category: "playlist")

    private static let playlistsKey = "playlists"
    private static let statesKey = "playlistStates"
    private static let activeKey = "activePlaylist"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastAppearanceWasDark = Self.isDark
        load()
    }

    // MARK: - Lifecycle

    public func start() {
        // Checked once a minute rather than on a tight tick. The finest trigger granularity the
        // UI offers is a minute, and a background app waking every second to ask whether it is
        // time yet is exactly the kind of idle cost this project exists to avoid.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 10

        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appearanceChanged() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }
    }

    // MARK: - Editing

    public func add(_ playlist: Playlist) {
        playlists.append(playlist)
        persist()
    }

    public func update(_ playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index] = playlist
        persist()
    }

    public func remove(_ id: Playlist.ID) {
        playlists.removeAll { $0.id == id }
        states.removeValue(forKey: id)
        if activePlaylistID == id { activePlaylistID = nil }
        persist()
    }

    public func activate(_ id: Playlist.ID?) {
        activePlaylistID = id
        persist()
        // Advance immediately so activating a playlist visibly does something, rather than
        // appearing inert until the first interval elapses.
        if id != nil { advanceNow() }
    }

    public func playlist(_ id: Playlist.ID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    // MARK: - Rotation

    private func tick(appearanceChanged: Bool = false) {
        guard let id = activePlaylistID, let playlist = playlist(id) else { return }
        let state = states[id] ?? .init()
        guard scheduler.shouldAdvance(
            playlist, state: state, now: .now, appearanceChanged: appearanceChanged
        ) else { return }
        advanceNow()
    }

    /// Advance the active playlist immediately, regardless of its trigger.
    public func advanceNow() {
        guard let id = activePlaylistID, let playlist = playlist(id) else { return }
        let state = states[id] ?? .init()
        guard let result = scheduler.advance(
            playlist, state: state, now: .now,
            isPlayable: { [weak self] in self?.isPlayable?($0) ?? true }
        ) else { return }

        states[id] = result.state
        persist()
        log.info("playlist \(playlist.name, privacy: .public) -> \(result.wallpaperID, privacy: .public)")
        onAdvance?(result.wallpaperID)
    }

    private func appearanceChanged() {
        let isDark = Self.isDark
        guard isDark != lastAppearanceWasDark else { return }
        lastAppearanceWasDark = isDark
        tick(appearanceChanged: true)
    }

    private static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: Self.playlistsKey),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = decoded
        }
        if let data = defaults.data(forKey: Self.statesKey),
           let decoded = try? JSONDecoder().decode(
            [String: PlaylistScheduler.State].self, from: data
           ) {
            // Keys are UUID strings on disk; anything unparseable is simply dropped, which at
            // worst restarts one rotation from the top.
            states = decoded.reduce(into: [:]) { result, pair in
                if let id = UUID(uuidString: pair.key) { result[id] = pair.value }
            }
        }
        if let raw = defaults.string(forKey: Self.activeKey), let id = UUID(uuidString: raw) {
            activePlaylistID = id
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(playlists) {
            defaults.set(data, forKey: Self.playlistsKey)
        }
        let keyed = states.reduce(into: [String: PlaylistScheduler.State]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        if let data = try? JSONEncoder().encode(keyed) {
            defaults.set(data, forKey: Self.statesKey)
        }
        if let activePlaylistID {
            defaults.set(activePlaylistID.uuidString, forKey: Self.activeKey)
        } else {
            defaults.removeObject(forKey: Self.activeKey)
        }
    }
}
