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
    private var popover: NSPopover?
    private var popoverMonitor: Any?
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var model: WallpaperSystemModel?
    private let log = Logger(subsystem: "app.diorama", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            presentFatal("Diorama needs a Metal-capable GPU, and this Mac does not have one.")
            return
        }
        log.info("Metal: \(device.name, privacy: .public), BC textures: \(device.supportsBCTextureCompression)")

        let controller = PlaybackController(coordinator: coordinator)
        playback = controller

        let model = WallpaperSystemModel(
            coordinator: coordinator, playback: controller, library: library
        )
        self.model = model

        setUpStatusItem()

        // Relay power decisions to whatever backend is playing. The backends never see the
        // policy directly; this is the single translation point.
        coordinator.policy.onDirectiveChange = { [weak self] displayID, directive in
            guard let self else { return }
            self.coordinator.surfaces[displayID]?.apply(directive)
            controller.applyDirective(directive, to: displayID)
            self.model?.refresh()
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
        defer { model?.refresh() }
        guard let playback else { return }
        // Every display gets the same wallpaper for now. Per-display assignment is a Pro feature
        // in Stage 2 (PLAN.md §10.2) and needs UI that does not exist yet.
        for displayID in coordinator.surfaces.keys {
            let report = playback.play(item, on: displayID)
            if !report.isFullySupported {
                log.info("\(item.title, privacy: .public): \(report.summary, privacy: .public)")
            }
        }
    }

    // MARK: - Windows

    @objc private func showLibrary(_ sender: Any?) {
        if let existing = libraryWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = LibraryView(store: library, systemModel: model) { [weak self] item in
            self?.play(item)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Diorama"
        window.contentView = NSHostingView(rootView: root)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
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
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        statusItem = item
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            closePopover()
            return
        }
        guard let button = statusItem?.button, let model else { return }

        model.refresh()

        let content = MenuBarView(
            model: model,
            onOpenLibrary: { [weak self] in
                self?.closePopover()
                self?.showLibrary(nil)
            },
            onOpenSettings: { [weak self] in
                self?.closePopover()
                self?.showSettings(nil)
            },
            onQuit: { NSApp.terminate(nil) }
        )

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 420)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: content)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover

        // `.transient` dismisses on most outside interaction, but not reliably when the click
        // lands on another app's window. This closes it in that case too, so the popover never
        // lingers over an app the user has moved on to.
        popoverMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        popover = nil
        if let popoverMonitor {
            NSEvent.removeMonitor(popoverMonitor)
            self.popoverMonitor = nil
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let model else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Diorama Settings"
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SettingsWindow")

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
