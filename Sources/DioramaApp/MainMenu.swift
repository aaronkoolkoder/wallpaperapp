import AppKit

/// Builds the application menu bar.
///
/// Not optional decoration. Without a main menu an app has no Quit item and **Cmd+Q does
/// nothing**, no Edit menu means Cmd+C/V/X are dead in every text field including search, and
/// Cmd+W will not close a window. All of that comes from the standard menu bar rather than from
/// AppKit's defaults, so an app that never sets `NSApp.mainMenu` is missing behaviour every Mac
/// user expects to work without thinking about it.
@MainActor
enum MainMenu {

    static func build(target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(appMenu(target: target))
        menu.addItem(editMenu())
        menu.addItem(wallpaperMenu(target: target))
        menu.addItem(windowMenu())
        menu.addItem(helpMenu())
        return menu
    }

    // MARK: - Diorama

    private static func appMenu(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Diorama")

        menu.addItem(
            withTitle: "About Diorama",
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ""
        ).target = target

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Settings…",
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ","
        ).target = target

        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Hide Diorama", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"
        )
        let hideOthers = menu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Quit Diorama",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        item.submenu = menu
        return item
    }

    // MARK: - Edit

    /// Standard editing. These selectors are dispatched through the responder chain, so they
    /// reach whatever text field is focused without the app wiring anything up.
    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())

        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )

        item.submenu = menu
        return item
    }

    // MARK: - Wallpaper

    private static func wallpaperMenu(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Wallpaper")

        menu.addItem(
            withTitle: "Wallpaper Library",
            action: #selector(AppDelegate.showLibrary(_:)),
            keyEquivalent: "l"
        ).target = target

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Pause",
            action: #selector(AppDelegate.togglePauseFromMenu(_:)),
            keyEquivalent: "p"
        ).target = target

        menu.addItem(
            withTitle: "Next in Playlist",
            action: #selector(AppDelegate.advancePlaylist(_:)),
            keyEquivalent: "n"
        ).target = target

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Remove Wallpaper from All Displays",
            action: #selector(AppDelegate.clearAllWallpapers(_:)),
            keyEquivalent: ""
        ).target = target

        item.submenu = menu
        return item
    }

    // MARK: - Window

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"
        )
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        // Cmd+W. Without it a window can only be closed with the mouse.
        menu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )

        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    // MARK: - Help

    private static func helpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(
            withTitle: "Diorama Help",
            action: #selector(AppDelegate.showLibrary(_:)),
            keyEquivalent: "?"
        )
        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }
}
