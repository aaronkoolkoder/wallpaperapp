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
