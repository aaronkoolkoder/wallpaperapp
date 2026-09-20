import AppKit
import Diagnostics
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
    private let playlists = PlaylistStore()
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

        // Without this there is no Quit item, Cmd+Q does nothing, and Cmd+C/V are dead in
        // every text field including the library search.
        NSApp.mainMenu = MainMenu.build(target: self)

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

        // Playlists drive playback through the same path the user's own clicks do.
        playlists.isPlayable = { [weak self] id in
            self?.library.item(withID: id)?.isPlayable ?? false
        }
        playlists.onAdvance = { [weak self] id in
            guard let self, let item = self.library.item(withID: id) else { return }
            self.play(item)
        }
        playlists.start()

        coordinator.start()

        // DIORAMA_LIBRARY=<path> imports a folder without the file panel, so the playback path
        // can be exercised from a script. Diagnostics only.
        if let path = ProcessInfo.processInfo.environment["DIORAMA_LIBRARY"] {
            log.warning("DIORAMA_LIBRARY is set; importing \(path, privacy: .public)")
            library.importLibrary(at: URL(fileURLWithPath: path))
        } else {
            library.restore()
        }

        // DIORAMA_STRESS=<cycles> repeatedly switches between every playable wallpaper and
        // reports resident memory, to catch resources that are not released on teardown. A
        // wallpaper app that leaks a few MB per switch looks fine in a demo and is unusable
        // after a week of real use, which is exactly the failure this is meant to surface.
        if let raw = ProcessInfo.processInfo.environment["DIORAMA_STRESS"],
           let cycles = Int(raw) {
            Task { @MainActor in await self.runStress(cycles: cycles) }
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

        // Always open the library on launch. A menu bar icon is easy to miss, and an app that
        // starts and visibly does nothing reads as broken — the first thing it does should be
        // to show you the thing it is for.
        if ProcessInfo.processInfo.environment["DIORAMA_PLAY"] == nil {
            showLibrary(nil)
        }
    }

    /// Clicking the Dock icon with no window open should bring the library back, not do nothing.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows { showLibrary(nil) }
        return true
    }

    /// Closing the last window must not quit: the wallpaper keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Show a Dock icon while a window is open, and drop back to menu-bar-only when none is.
    ///
    /// A permanent Dock icon is clutter for something that mostly sits in the background, but
    /// `.accessory` alone means a missed menu bar item leaves no way into the app at all — and
    /// an accessory app's windows cannot properly own the menu bar, so Cmd+Q and Cmd+W behave
    /// oddly even once the menu exists.
    func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains {
            $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
        }
        let wanted: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        log.info("activation policy -> \(wanted == .regular ? "regular (dock)" : "accessory")")
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.audioCapture.stop()
        playlists.stop()
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

    /// Cycle every playable wallpaper `cycles` times, sampling memory between passes.
    private func runStress(cycles: Int) async {
        for _ in 0 ..< 60 where library.items.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let playable = library.items.filter(\.isPlayable)
        guard !playable.isEmpty else {
            log.error("stress: no playable wallpapers")
            NSApp.terminate(nil)
            return
        }

        log.info("stress: \(cycles) cycle(s) over \(playable.count) wallpaper(s)")
        let baseline = Self.residentBytes()
        print("stress baseline: \(Self.format(baseline))")

        // Counted and printed rather than logged: this process's os_log output does not reach
        // `log show` from a plain binary launch, so a logged-only count cannot be checked.
        var scenesPlayed = 0
        var blankFirstFrames = 0
        var firstFrameDetails: Set<String> = []

        for cycle in 1 ... cycles {
            for item in playable {
                let reports = playAndReport(item)
                if item.type == .scene {
                    scenesPlayed += reports.count
                    for report in reports {
                        for finding in report.findings
                        where finding.detail?.contains("first frame") == true {
                            blankFirstFrames += 1
                            if let detail = finding.detail { firstFrameDetails.insert(detail) }
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(220))
            }
            playback?.stopAll()
            try? await Task.sleep(for: .milliseconds(120))

            let now = Self.residentBytes()
            let delta = Int64(now) - Int64(baseline)
            print(
                "cycle \(cycle): \(Self.format(now)) "
                + "(\(delta >= 0 ? "+" : "")\(Self.format(UInt64(abs(delta)))) vs baseline)"
            )
        }

        print("scenes played: \(scenesPlayed), blank first frames: \(blankFirstFrames)")
        for detail in firstFrameDetails.prefix(3) { print("  \(detail)") }
        NSApp.terminate(nil)
    }

    /// Like `play`, but hands back what each display reported.
    @discardableResult
    private func playAndReport(_ item: WallpaperItem) -> [CompatibilityReport] {
        defer { model?.refresh() }
        guard let playback else { return [] }
        return coordinator.surfaces.keys.map { playback.play(item, on: $0) }
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private static func format(_ bytes: UInt64) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }

    // MARK: - Windows

    // MARK: - Menu actions

    @objc func togglePauseFromMenu(_ sender: Any?) {
        model?.togglePause()
    }

    @objc func advancePlaylist(_ sender: Any?) {
        playlists.advanceNow()
    }

    @objc func clearAllWallpapers(_ sender: Any?) {
        playback?.stopAll()
        model?.refresh()
    }

    @objc func showLibrary(_ sender: Any?) {
        if let existing = libraryWindow {
            existing.makeKeyAndOrderFront(nil)
            updateActivationPolicy()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = LibraryView(
            store: library,
            systemModel: model,
            playlists: playlists,
            onPlay: { [weak self] item in self?.play(item) },
            onPlayOnDisplay: { [weak self] item, displayID in
                self?.model?.play(item, on: displayID)
            }
        )
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
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        // After ordering front, not before: the window is not yet visible when it is created,
        // so counting visible windows first always concludes there are none.
        updateActivationPolicy()
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

    @objc func showSettings(_ sender: Any?) {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            updateActivationPolicy()
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
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        // After ordering front, not before: the window is not yet visible when it is created,
        // so counting visible windows first always concludes there are none.
        updateActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Drop the Dock icon once the last window goes away, on the next turn of the run loop so
    /// the window has actually been removed from `NSApp.windows` by the time we count them.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy()
        }
    }
}
