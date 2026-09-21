import CoreGraphics
import Foundation
import LibraryKit
import Testing
@testable import PlayerCore

/// What makes "open at login" mean anything: the wallpaper has to be there when the app comes
/// back, without the user opening the library and clicking it again.
@Suite("WallpaperSessionStore")
@MainActor
struct WallpaperSessionStoreTests {

    /// Fresh storage per test, in memory — never a real `UserDefaults` suite, which writes a
    /// plist into the user's home directory that a parallel run then races to delete.
    private func withDefaults(_ body: (any PreferenceStorage) throws -> Void) rethrows {
        try body(InMemoryPreferences())
    }

    private let display: CGDirectDisplayID = 1

    @Test("A wallpaper playing at quit is still assigned at the next launch")
    func rememberSurvivesRelaunch() {
        withDefaults { defaults in
            WallpaperSessionStore(defaults: defaults).remember("2641662373", on: display)

            let nextLaunch = WallpaperSessionStore(defaults: defaults)
            #expect(nextLaunch.wallpaperID(for: display) == "2641662373")
            #expect(!nextLaunch.isEmpty)
        }
    }

    @Test("Clearing a display is remembered as clear, not as the old wallpaper")
    func forgetSurvivesRelaunch() {
        withDefaults { defaults in
            let store = WallpaperSessionStore(defaults: defaults)
            store.remember("2641662373", on: display)
            store.forget(display)

            #expect(WallpaperSessionStore(defaults: defaults).wallpaperID(for: display) == nil)
            #expect(WallpaperSessionStore(defaults: defaults).isEmpty)
        }
    }

    @Test("A display with nothing of its own falls back to the most recent assignment")
    func unknownDisplayFallsBack() {
        // A laptop last used docked, now undocked, should come back to the user's wallpaper
        // rather than to an empty desktop.
        withDefaults { defaults in
            let store = WallpaperSessionStore(defaults: defaults)
            store.remember("2641662373", on: display)

            #expect(store.wallpaperID(for: 99) == nil)
            #expect(store.anyWallpaperID == "2641662373")
        }
    }

    @Test("Nothing stored is not an error, just nothing to restore")
    func emptyIsNotAnError() {
        withDefaults { defaults in
            let store = WallpaperSessionStore(defaults: defaults)
            #expect(store.isEmpty)
            #expect(store.anyWallpaperID == nil)
        }
    }

    @Test("Corrupt stored data starts clean rather than refusing to launch")
    func survivesCorruptData() {
        withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: "app.diorama.session")
            let store = WallpaperSessionStore(defaults: defaults)
            #expect(store.isEmpty)

            store.remember("123", on: display)
            #expect(store.wallpaperID(for: display) == "123")
        }
    }

    @Test("A display that cannot be resolved does not inherit the built-in panel's wallpaper")
    func unresolvableDisplayIsNotBuiltin() {
        // `CGDisplayIsBuiltin` answers -1, not 0, for an id it cannot resolve, so a check
        // against 0 files every unknown display under the built-in panel's key — and the
        // laptop's wallpaper then appears on a monitor the user never assigned one to.
        #expect(
            WallpaperSessionStore.key(for: 99)
                != WallpaperSessionStore.key(for: CGMainDisplayID())
        )
    }

    @Test("The key identifies the panel, not the session's display number")
    func keyIsStable() {
        // `CGDirectDisplayID` is handed out per session, so storing one would restore the
        // wallpaper onto whichever display inherited the number after a reboot.
        let key = WallpaperSessionStore.key(for: display)
        #expect(key == WallpaperSessionStore.key(for: display), "the key is not deterministic")
        #expect(!key.isEmpty)
    }
}
