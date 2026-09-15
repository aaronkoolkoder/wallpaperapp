import AppKit
import LibraryKit
import Metal
import PlayerCore
import SwiftUI
import WallpaperKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = DisplayCoordinator()
    private let library = LibraryStore()
    private var playback: PlaybackController?

    private var statusItem: NSStatusItem?
    private var libraryWindow: NSWindow?
    private let log = Logger(subsystem: "app.diorama", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            presentFatal("Diorama needs a Metal-capable GPU, and this Mac does not have one.")
            return
        }
        log.info("Metal: \(device.name, privacy: .public), BC textures: \(device.supportsBCTextureCompression)")

        let controller = PlaybackController(coordinator: coordinator)
        playback = controller

        setUpStatusItem()

        // Relay power decisions to whatever backend is playing. The backends never see the
        // policy directly; this is the single translation point.
        coordinator.policy.onDirectiveChange = { [weak self] displayID, directive in
            guard let self else { return }
            self.coordinator.surfaces[displayID]?.apply(directive)
            controller.applyDirective(directive, to: displayID)
        }

        if ProcessInfo.processInfo.environment["DIORAMA_FORCE_RENDER"] == "1" {
            var preferences = PowerPreferences.default
            preferences.suspendWhenOccluded = false
            preferences.suspendUnderFullscreenApps = false
            preferences.suspendInLowPowerMode = false
            coordinator.setPreferences(preferences)
            log.warning("DIORAMA_FORCE_RENDER is set; occlusion suspension disabled")
        }

        coordinator.start()

        // DIORAMA_LIBRARY=<path> imports a folder without the file panel, so the playback path
        // can be exercised from a script. Diagnostics only.
        if let path = ProcessInfo.processInfo.environment["DIORAMA_LIBRARY"] {
            log.warning("DIORAMA_LIBRARY is set; importing \(path, privacy: .public)")
            library.importLibrary(at: URL(fileURLWithPath: path))
        } else {
            library.restore()
        }

        // DIORAMA_PLAY=<workshop-id> starts a wallpaper once the scan finishes.
        if let wanted = ProcessInfo.processInfo.environment["DIORAMA_PLAY"] {
            Task { @MainActor in
                for _ in 0 ..< 50 where self.library.item(withID: wanted) == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let item = self.library.item(withID: wanted) {
                    self.play(item)
                } else {
                    self.log.error("DIORAMA_PLAY: no wallpaper with id \(wanted, privacy: .public)")
                }
            }
        }

        // No library yet means nothing can play, so send the user somewhere useful rather than
        // leaving a menu bar icon that appears to do nothing.
        if library.rootURL == nil { showLibrary(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        playback?.stopAll()
        coordinator.stop()
    }

    // MARK: - Playing

    private func play(_ item: WallpaperItem) {
        guard let playback else { return }
        // Every display gets the same wallpaper for now. Per-display assignment is a Pro feature
        // in Stage 2 (PLAN.md §10.2) and needs UI that does not exist yet.
        for displayID in coordinator.surfaces.keys {
            let report = playback.play(item, on: displayID)
            if !report.isFullySupported {
                log.info("\(item.title, privacy: .public): \(report.summary, privacy: .public)")
            }
        }
        refreshMenu()
    }

    // MARK: - Windows

    @objc private func showLibrary(_ sender: Any?) {
        if let existing = libraryWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = LibraryView(store: library) { [weak self] item in self?.play(item) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Diorama"
        window.contentView = NSHostingView(rootView: root)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("LibraryWindow")

        libraryWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Diorama can't start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "sparkles.rectangle.stack",
            accessibilityDescription: "Diorama"
        )
        item.menu = buildMenu()
        statusItem = item
    }

    private enum MenuTag: Int {
        case status = 1
        case pause = 2
        case nowPlaying = 3
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let nowPlaying = NSMenuItem(title: "No wallpaper set", action: nil, keyEquivalent: "")
        nowPlaying.isEnabled = false
        nowPlaying.tag = MenuTag.nowPlaying.rawValue
        menu.addItem(nowPlaying)

        let status = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = MenuTag.status.rawValue
        menu.addItem(status)

        menu.addItem(.separator())

        let libraryItem = NSMenuItem(
            title: "Wallpaper Library…", action: #selector(showLibrary(_:)), keyEquivalent: "l"
        )
        libraryItem.target = self
        menu.addItem(libraryItem)

        let pause = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        pause.tag = MenuTag.pause.rawValue
        menu.addItem(pause)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Diorama", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func togglePause() {
        coordinator.policy.isUserPaused.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menuWillOpen(menu)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Refreshed only while the menu is open. Updating on a timer would mean doing work every
    /// second in order to describe how little work we are doing.
    func menuWillOpen(_ menu: NSMenu) {
        if let item = menu.item(withTag: MenuTag.nowPlaying.rawValue) {
            let displays = coordinator.surfaces.keys.sorted()
            if let first = displays.first, let current = playback?.currentItem(for: first) {
                item.title = current.title
            } else {
                item.title = "No wallpaper set"
            }
        }
        if let item = menu.item(withTag: MenuTag.status.rawValue) {
            item.title = statusSummary()
        }
        if let item = menu.item(withTag: MenuTag.pause.rawValue) {
            item.title = coordinator.policy.isUserPaused ? "Resume" : "Pause"
        }
    }

    private func statusSummary() -> String {
        let surfaces = coordinator.surfaces
        guard !surfaces.isEmpty else { return "No displays" }

        let running = surfaces.values.filter { !$0.directive.isSuspended }
        guard !running.isEmpty else {
            if case .suspended(let reason) = surfaces.values.first?.directive {
                return "Idle — \(reason.description)"
            }
            return "Idle"
        }
        let fps = running.map(\.directive.frameRate).max() ?? 0
        return "\(running.count) of \(surfaces.count) display\(surfaces.count == 1 ? "" : "s") · \(fps)fps"
    }
}
