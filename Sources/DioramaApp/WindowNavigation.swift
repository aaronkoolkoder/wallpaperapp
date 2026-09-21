import Observation

/// The panes in Diorama's settings group.
enum SettingsPane: String, Hashable, CaseIterable, Identifiable {
    case general, performance, displays, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .performance: "Performance"
        case .displays: "Displays"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .performance: "bolt"
        case .displays: "display"
        case .about: "info.circle"
        }
    }
}

/// Everything the one window can show.
///
/// Diorama runs in the background from the menu bar, and the only thing it ever puts on screen
/// besides the wallpaper is this window. Browsing wallpapers and changing settings are both
/// destinations in the same sidebar — the System Settings pattern — rather than two windows
/// that each need finding, sizing and closing.
enum SidebarDestination: Hashable {
    case library(LibraryFilter)
    case settings(SettingsPane)

    var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }
}

/// Which destination the window is showing.
///
/// Owned by the app delegate rather than by the view, so the menu bar popover, Cmd+, and the
/// About item can each open the window at the right place.
@MainActor
@Observable
final class WindowNavigation {
    var destination: SidebarDestination = .library(.all) {
        // Recorded on every change, not only in `show(_:)`: the sidebar binds straight to
        // `destination`, so a user who picks Scenes and then clicks General never goes through
        // any method here.
        didSet { if case .library(let filter) = destination { lastFilter = filter } }
    }

    /// Show the library, keeping whichever filter the user last picked rather than resetting
    /// to All every time the window is brought forward.
    func showLibrary() {
        if !destination.isLibrary { destination = .library(lastFilter) }
    }

    func show(_ pane: SettingsPane) {
        destination = .settings(pane)
    }

    @ObservationIgnored private(set) var lastFilter: LibraryFilter = .all
}
