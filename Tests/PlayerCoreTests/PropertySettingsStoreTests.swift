import Foundation
import LibraryKit
import Testing
import WEFormat
@testable import PlayerCore

@Suite("PropertySettingsStore")
struct PropertySettingsStoreTests {

    /// Fresh storage per test, in memory.
    ///
    /// Never a real `UserDefaults` suite: that writes a plist into the user's home directory,
    /// and deleting it afterwards races with `cfprefsd` writing it back, so a parallel test run
    /// leaves strays behind however carefully it tidies up.
    private func withDefaults(_ body: (any PreferenceStorage) throws -> Void) rethrows {
        try body(InMemoryPreferences())
    }

    @Test("A changed value is remembered")
    func remembersChanges() {
        withDefaults { defaults in
            let store = PropertySettingsStore(defaults: defaults)
            store.set(.number(0.75), for: "speed", on: "123")
            #expect(store.properties(for: "123")["speed"] == .number(0.75))
        }
    }

    @Test("Only changed values are stored")
    func storesOnlyChanges() {
        withDefaults { defaults in
            // Recording a wallpaper's full set would pin every property to whatever it was the first
            // time it was opened, so a later update to the wallpaper would appear to do nothing.
            let store = PropertySettingsStore(defaults: defaults)
            store.set(.number(0.75), for: "speed", on: "123")
            #expect(store.properties(for: "123").count == 1)
            #expect(store.properties(for: "123")["colour"] == nil)
        }
    }

    @Test("Clearing a value restores the author's rather than storing a copy of it")
    func clearingRemoves() {
        withDefaults { defaults in
            let store = PropertySettingsStore(defaults: defaults)
            store.set(.number(0.75), for: "speed", on: "123")
            store.set(nil, for: "speed", on: "123")
            #expect(store.properties(for: "123").isEmpty)
            #expect(store.customisedWallpaperCount == 0)
        }
    }

    @Test("Wallpapers do not see each other's settings")
    func isolatesWallpapers() {
        withDefaults { defaults in
            let store = PropertySettingsStore(defaults: defaults)
            store.set(.number(1), for: "speed", on: "111")
            store.set(.number(2), for: "speed", on: "222")
            #expect(store.properties(for: "111")["speed"] == .number(1))
            #expect(store.properties(for: "222")["speed"] == .number(2))
        }
    }

    @Test("Resetting clears one wallpaper and leaves the rest")
    func resetsOneWallpaper() {
        withDefaults { defaults in
            let store = PropertySettingsStore(defaults: defaults)
            store.set(.number(1), for: "speed", on: "111")
            store.set(.number(2), for: "speed", on: "222")
            store.reset("111")
            #expect(store.properties(for: "111").isEmpty)
            #expect(store.properties(for: "222")["speed"] == .number(2))
        }
    }

    @Test("Settings survive into a new store over the same defaults")
    func persistsAcrossLaunches() {
        withDefaults { defaults in
                        PropertySettingsStore(defaults: defaults).set(.string("1 0 0"), for: "tint", on: "123")

            let reopened = PropertySettingsStore(defaults: defaults)
            #expect(reopened.properties(for: "123")["tint"] == .string("1 0 0"))
        }
    }

    @Test("Corrupt stored data starts clean rather than refusing to launch")
    func survivesCorruptData() {
        withDefaults { defaults in
            // The worst case is a user's tweaks reverting to the wallpaper's own values, which is a
            // great deal better than an app that will not open.
                        defaults.set(Data("not json".utf8), forKey: "app.diorama.wallpaperProperties")

            let store = PropertySettingsStore(defaults: defaults)
            #expect(store.customisedWallpaperCount == 0)
            store.set(.number(1), for: "speed", on: "123")
            #expect(store.properties(for: "123")["speed"] == .number(1))
        }
    }

    @Test("An unknown wallpaper has no settings rather than failing")
    func unknownWallpaperIsEmpty() {
        withDefaults { defaults in
            #expect(PropertySettingsStore(defaults: defaults).properties(for: "nope").isEmpty)
        }
    }
}
