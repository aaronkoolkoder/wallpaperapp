import Foundation
import LibraryKit
import WEFormat
import os

/// Remembers the settings a user has changed on individual wallpapers.
///
/// Only *changed* values are stored. A wallpaper's own defaults live in its manifest and its
/// shader annotations, so recording the full set would pin every property to whatever it was the
/// first time the wallpaper was opened — and a later update to the wallpaper would appear to do
/// nothing. Clearing a property here restores the author's value rather than storing a copy of it.
public final class PropertySettingsStore: @unchecked Sendable {
    private let defaults: any PreferenceStorage
    private let key = "app.diorama.wallpaperProperties"
    private let log = Logger(subsystem: "app.diorama", category: "settings")

    /// Wallpaper ID to the properties the user has changed on it.
    private var storage: [String: [String: DynamicValue]]

    public init(defaults: any PreferenceStorage = UserDefaults.standard) {
        self.defaults = defaults
        storage = Self.load(from: defaults, key: "app.diorama.wallpaperProperties")
    }

    public func properties(for wallpaperID: String) -> [String: DynamicValue] {
        storage[wallpaperID] ?? [:]
    }

    /// Records one changed value, or clears it when `value` is nil.
    public func set(_ value: DynamicValue?, for property: String, on wallpaperID: String) {
        var current = storage[wallpaperID] ?? [:]
        if let value {
            current[property] = value
        } else {
            current.removeValue(forKey: property)
        }
        if current.isEmpty {
            storage.removeValue(forKey: wallpaperID)
        } else {
            storage[wallpaperID] = current
        }
        persist()
    }

    /// Restores every property on a wallpaper to what its author shipped.
    public func reset(_ wallpaperID: String) {
        guard storage.removeValue(forKey: wallpaperID) != nil else { return }
        persist()
    }

    public var customisedWallpaperCount: Int { storage.count }

    // MARK: - Persistence

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(storage), forKey: key)
        } catch {
            // Losing a preference is not worth failing anything over, but it should not be
            // silent either: the user would see their settings quietly not stick.
            log.error("could not save wallpaper settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from defaults: any PreferenceStorage, key: String) -> [String: [String: DynamicValue]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        do {
            return try JSONDecoder().decode([String: [String: DynamicValue]].self, from: data)
        } catch {
            // Corrupt or from an older shape: start clean rather than refusing to launch. The
            // worst case is a user's tweaks reverting to the wallpaper's own defaults.
            return [:]
        }
    }
}
