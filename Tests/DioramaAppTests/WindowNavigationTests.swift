import Testing
@testable import DioramaApp

/// The one window's routing: library filters and settings panes share a sidebar, and the
/// menu bar, Cmd+, and About each have to land in the right place.
@Suite("WindowNavigation")
@MainActor
struct WindowNavigationTests {

    @Test("A fresh window opens on the whole library")
    func startsOnTheLibrary() {
        #expect(WindowNavigation().destination == .library(.all))
    }

    @Test("Coming back from settings restores the filter the user had picked")
    func libraryRemembersItsFilter() {
        let navigation = WindowNavigation()
        navigation.destination = .library(.scenes)
        navigation.show(.performance)
        navigation.showLibrary()
        #expect(navigation.destination == .library(.scenes))
    }

    @Test("The filter is remembered when settings are reached through the sidebar itself")
    func sidebarClicksAreRemembered() {
        // The sidebar binds straight to `destination`, so clicking General never goes through
        // `show(_:)`. Remembering the filter only there would reset the library to All.
        let navigation = WindowNavigation()
        navigation.destination = .library(.videos)
        navigation.destination = .settings(.general)
        navigation.showLibrary()
        #expect(navigation.destination == .library(.videos))
    }

    @Test("Bringing the library forward does not reset a filter already showing")
    func showLibraryIsIdempotent() {
        let navigation = WindowNavigation()
        navigation.destination = .library(.web)
        navigation.showLibrary()
        #expect(navigation.destination == .library(.web))
    }

    @Test("Opening a settings pane goes straight to it")
    func showsThePane() {
        let navigation = WindowNavigation()
        navigation.show(.about)
        #expect(navigation.destination == .settings(.about))
        #expect(!navigation.destination.isLibrary)
    }
}

/// Getting back into an app that has no Dock icon.
@Suite("Reopening")
@MainActor
struct ReopeningTests {

    /// The bug this exists for. `applicationShouldHandleReopen` was deciding from
    /// `hasVisibleWindows`, and this app's windows are mostly the wallpaper surfaces — one per
    /// display, ordered front, visible by every measure AppKit has. With a wallpaper playing
    /// the answer was always yes, so clicking the app did nothing, and with the menu bar item
    /// hidden behind a notched display's camera housing there was no way back to the library
    /// at all. Asked about the library window instead, the answer is the one the user means.
    @Test("A playing wallpaper is not a reason to withhold the library window")
    func wallpaperSurfacesAreNotTheLibrary() {
        #expect(AppDelegate.reopenAction(
            libraryIsVisible: false, libraryIsMiniaturised: false
        ) == .present)
    }

    @Test("A library window already open is raised rather than remade")
    func raisesAnOpenWindow() {
        #expect(AppDelegate.reopenAction(
            libraryIsVisible: true, libraryIsMiniaturised: false
        ) == .bringToFront)
    }

    @Test("A window in the Dock is brought back out of it")
    func deminiaturises() {
        // Ordering a miniaturised window to the front leaves it in the Dock, which from the
        // outside is indistinguishable from the app ignoring the click.
        #expect(AppDelegate.reopenAction(
            libraryIsVisible: true, libraryIsMiniaturised: true
        ) == .present)
    }
}
