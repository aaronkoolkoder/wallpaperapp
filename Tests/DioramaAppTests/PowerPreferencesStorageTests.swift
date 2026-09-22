import Foundation
import Testing
import WallpaperKit
@testable import DioramaApp

@Suite("PowerPreferencesStorage")
struct PowerPreferencesStorageTests {

    private func scratchDefaults() -> UserDefaults {
        let name = "diorama-power-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Nothing saved means the defaults")
    func defaultsWhenEmpty() {
        #expect(PowerPreferencesStorage.load(from: scratchDefaults()) == .default)
    }

    @Test("What is saved is what loads, so a setting survives a relaunch")
    func survivesRelaunch() {
        let defaults = scratchDefaults()
        var preferences = PowerPreferences.default
        preferences.suspendUnderFullscreenApps = false
        preferences.suspendWhenAnotherAppIsActive = true
        preferences.batteryFloorPercent = 50
        PowerPreferencesStorage.save(preferences, to: defaults)
        #expect(PowerPreferencesStorage.load(from: defaults) == preferences)
    }

    @Test("Something unreadable falls back to the defaults rather than failing")
    func unreadable() {
        let defaults = scratchDefaults()
        defaults.set(Data("not json".utf8), forKey: PowerPreferencesStorage.key)
        #expect(PowerPreferencesStorage.load(from: defaults) == .default)
    }
}
