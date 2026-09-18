import Foundation
import Testing
import WEFormat
@testable import PlayerCore

@Suite("PropertySettingsStore")
struct PropertySettingsStoreTests {

    /// A private suite per test, so nothing touches the user's real preferences and tests do not
    /// see each other's writes.
    private func makeDefaults() -> UserDefaults {
        let name = "app.diorama.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A changed value is remembered")
    func remembersChanges() {
        let store = PropertySettingsStore(defaults: makeDefaults())
        store.set(.number(0.75), for: "speed", on: "123")
        #expect(store.properties(for: "123")["speed"] == .number(0.75))
    }

    @Test("Only changed values are stored")
    func storesOnlyChanges() {
        // Recording a wallpaper's full set would pin every property to whatever it was the first
        // time it was opened, so a later update to the wallpaper would appear to do nothing.
        let store = PropertySettingsStore(defaults: makeDefaults())
        store.set(.number(0.75), for: "speed", on: "123")
        #expect(store.properties(for: "123").count == 1)
        #expect(store.properties(for: "123")["colour"] == nil)
    }

    @Test("Clearing a value restores the author's rather than storing a copy of it")
    func clearingRemoves() {
        let store = PropertySettingsStore(defaults: makeDefaults())
        store.set(.number(0.75), for: "speed", on: "123")
        store.set(nil, for: "speed", on: "123")
        #expect(store.properties(for: "123").isEmpty)
        #expect(store.customisedWallpaperCount == 0)
    }

    @Test("Wallpapers do not see each other's settings")
    func isolatesWallpapers() {
        let store = PropertySettingsStore(defaults: makeDefaults())
        store.set(.number(1), for: "speed", on: "111")
        store.set(.number(2), for: "speed", on: "222")
        #expect(store.properties(for: "111")["speed"] == .number(1))
        #expect(store.properties(for: "222")["speed"] == .number(2))
    }

    @Test("Resetting clears one wallpaper and leaves the rest")
    func resetsOneWallpaper() {
        let store = PropertySettingsStore(defaults: makeDefaults())
        store.set(.number(1), for: "speed", on: "111")
        store.set(.number(2), for: "speed", on: "222")
        store.reset("111")
        #expect(store.properties(for: "111").isEmpty)
        #expect(store.properties(for: "222")["speed"] == .number(2))
    }

    @Test("Settings survive into a new store over the same defaults")
    func persistsAcrossLaunches() {
        let defaults = makeDefaults()
        PropertySettingsStore(defaults: defaults).set(.string("1 0 0"), for: "tint", on: "123")

        let reopened = PropertySettingsStore(defaults: defaults)
        #expect(reopened.properties(for: "123")["tint"] == .string("1 0 0"))
    }

    @Test("Corrupt stored data starts clean rather than refusing to launch")
    func survivesCorruptData() {
        // The worst case is a user's tweaks reverting to the wallpaper's own values, which is a
        // great deal better than an app that will not open.
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "app.diorama.wallpaperProperties")

        let store = PropertySettingsStore(defaults: defaults)
        #expect(store.customisedWallpaperCount == 0)
        store.set(.number(1), for: "speed", on: "123")
        #expect(store.properties(for: "123")["speed"] == .number(1))
    }

    @Test("An unknown wallpaper has no settings rather than failing")
    func unknownWallpaperIsEmpty() {
        #expect(PropertySettingsStore(defaults: makeDefaults()).properties(for: "nope").isEmpty)
    }
}
