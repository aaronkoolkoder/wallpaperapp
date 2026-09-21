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
    /// The app's only window: the library, with settings as a second sidebar group.
    private var window: NSWindow?
    private let navigation = WindowNavigation()
    private var model: WallpaperSystemModel?
    private let log = Logger(subsystem: "app.diorama", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A background app: the menu bar item and the wallpaper, no Dock icon, ever. The bundle
        // declares LSUIElement so there is not even a flash of one at launch; this covers a run
        // straight from `swift run`, where there is no bundle to declare it.
        NSApp.setActivationPolicy(.accessory)

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
        // DIORAMA_HOLD=<id> plays one wallpaper, prints the surface's window number, and stays
        // up so the window itself can be captured. Capturing our own window answers "is this
        // drawing" directly, without photographing anything of the user's.
        if let wanted = ProcessInfo.processInfo.environment["DIORAMA_HOLD"] {
            Task { @MainActor in
                for _ in 0 ..< 80 where self.library.items.isEmpty {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let item = self.library.items.first(where: { $0.id == wanted })
                    ?? self.library.items.first(where: { $0.type == .scene && $0.isPlayable })
                else { print("hold: nothing to play"); return }

                self.play(item)
                try? await Task.sleep(for: .seconds(2))
                for surface in self.coordinator.surfaces.values {
                    print("hold: window=\(surface.windowNumber) display=\(surface.displayID) "
                          + "occluded=\(surface.isOccluded) title=\(item.title)")
                }
                if let playback = self.playback {
                    for display in self.coordinator.surfaces.keys {
                        print("hold: frames=\(playback.framesRendered(on: display)) "
                              + "suspended=\(playback.isSuspended(on: display))")
                    }
                }
                print("hold: ready")
                // Stdout is block-buffered into a pipe, and this process is killed rather than
                // exiting, so without this the whole diagnostic is lost.
                fflush(stdout)
            }
        }

        // DIORAMA_SELFTEST=window drives the one-window shape inside the real app and exits
        // with a status: activation policy, routing into settings, and whether ⌘W and ⌘, still
        // reach the menu when there is no menu bar showing. Keystrokes are synthesised and
        // handed to this process's own dispatch — never posted system-wide — so nothing typed
        // here can land in another app.
        if ProcessInfo.processInfo.environment["DIORAMA_SELFTEST"] == "window" {
            Task { @MainActor in await self.runWindowSelfTest() }
        }

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

        // Put back whatever was playing, then decide whether to show anything.
        //
        // Opening the library unconditionally is wrong once the app starts at login: the first
        // thing the user would see every morning is a window they did not ask for. Opening it
        // only when there was nothing to restore gives both behaviours from one rule — a first
        // launch still shows the thing the app is for, and a login launch is silent.
        if ProcessInfo.processInfo.environment["DIORAMA_PLAY"] == nil,
           ProcessInfo.processInfo.environment["DIORAMA_HOLD"] == nil,
           ProcessInfo.processInfo.environment["DIORAMA_STRESS"] == nil,
           ProcessInfo.processInfo.environment["DIORAMA_SELFTEST"] == nil {
            Task { @MainActor in
                let restored = await self.restoreSession()
                if !restored { self.showLibrary(nil) }
            }
        }
    }

    /// Replay the wallpapers this Mac had before the app last quit.
    ///
    /// - Returns: whether anything was put back.
    private func restoreSession() async -> Bool {
        guard let playback, !playback.session.isEmpty else { return false }

        // The scan runs off the main actor, so the library is empty for a moment after launch.
        // Waiting on it is what makes this work on a cold boot, where the app starts before the
        // disk has warmed up.
        for _ in 0 ..< 80 where library.items.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }

        // The fallback below is only for the case where none of the displays attached right
        // now is one we have an assignment for — a laptop last used docked, now on its own.
        // Applying it per display instead would put the built-in panel's wallpaper onto an
        // external monitor the user had deliberately left clear.
        let main = CGMainDisplayID()
        let recognised = coordinator.surfaces.keys
            .contains { playback.session.wallpaperID(for: $0) != nil }

        var restoredAny = false
        for display in coordinator.surfaces.keys {
            let fallback = (!recognised && display == main) ? playback.session.anyWallpaperID : nil
            guard let wanted = playback.session.wallpaperID(for: display) ?? fallback,
                  let item = library.item(withID: wanted), item.isPlayable
            else { continue }
            _ = playback.play(item, on: display)
            restoredAny = true
            log.info("restored \(item.title, privacy: .public) on display \(display)")
        }
        model?.refresh()
        return restoredAny
    }

    /// Opening Diorama again while it is running — from Finder, Launchpad or Spotlight — shows
    /// the window.
    ///
    /// This is the way back in when the menu bar item cannot be reached. On a notched display a
    /// crowded menu bar hides items behind the camera housing, and a background app whose only
    /// door is a hidden icon would otherwise be impossible to open short of killing it.
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
        // The default action puts the wallpaper on every display. Choosing one display is the
        // inspector's per-display buttons, through `WallpaperSystemModel.play(_:on:)`.
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

        // Whether a wallpaper *animates* is the other half, and just as unobservable: a scene
        // stuck on its first frame looks exactly like one running on still content. Play one,
        // hold, and see whether the frame count moves.
        if let last = playable.last(where: { $0.type == .scene }), let playback {
            playAndReport(last)
            try? await Task.sleep(for: .milliseconds(400))
            let first = coordinator.surfaces.keys.map { playback.framesRendered(on: $0) }
            try? await Task.sleep(for: .seconds(2))
            for display in coordinator.surfaces.keys.sorted() {
                let now = playback.framesRendered(on: display)
                let before = first.first ?? 0
                print(
                    "animation on \(display): \(before) -> \(now) frames over 2s, "
                    + "suspended=\(playback.isSuspended(on: display))"
                )
            }
        }
        for detail in firstFrameDetails.prefix(3) { print("  \(detail)") }


        // Every window we own, on screen or not, with the level the window server gave it.
        // `excludeDesktopElements` would filter out exactly the kind of window this app makes.
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = all.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == getpid() }
        print("our windows: \(mine.count)")
        for window in mine {
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            print(
                "  level=\(window[kCGWindowLayer as String] as? Int ?? -999)"
                + " onscreen=\(window[kCGWindowIsOnscreen as String] as? Bool ?? false)"
                + " alpha=\(window[kCGWindowAlpha as String] as? Double ?? -1)"
                + " size=\(bounds["Width"] ?? "?")x\(bounds["Height"] ?? "?")"
            )
        }
        for surface in coordinator.surfaces.values {
            print("  surface \(surface.displayID): occluded=\(surface.isOccluded)")
        }
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
        navigation.showLibrary()
        presentWindow()
    }

    /// Settings are a destination in the one window, not a window of their own.
    @objc func showSettings(_ sender: Any?) {
        if case .settings = navigation.destination {} else { navigation.show(.general) }
        presentWindow()
    }

    @objc func showAbout(_ sender: Any?) {
        navigation.show(.about)
        presentWindow()
    }

    private func presentWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = LibraryView(
            store: library,
            systemModel: model,
            playlists: playlists,
            navigation: navigation,
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
        // The library window's old name, so a frame the user already arranged is kept.
        window.setFrameAutosaveName("LibraryWindow")
        window.delegate = self

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func runWindowSelfTest() async {
        var failures = 0
        func check(_ passed: Bool, _ claim: String) {
            print("selftest: \(passed ? "ok  " : "FAIL") \(claim)")
            if !passed { failures += 1 }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
        // With DIORAMA_SELFTEST_PAUSE set, each destination is held long enough for a script to
        // capture this one window by number — the way to look at the real layout, since the
        // sidebar, forms and inspector are AppKit-backed and do not draw offscreen.
        let pauses = ProcessInfo.processInfo.environment["DIORAMA_SELFTEST_PAUSE"] != nil
        func hold(_ label: String) async {
            guard pauses, let window else { return }
            print("selftest: showing \(label) window=\(window.windowNumber)")
            fflush(stdout)
            try? await Task.sleep(for: .seconds(3))
        }
        func command(_ character: String, keyCode: UInt16) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0, context: nil,
                characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: keyCode
            )
        }

        check(NSApp.activationPolicy() == .accessory, "runs as a background app, no Dock icon")
        let ours = NSApp.windows.filter { $0.canBecomeMain && $0.isVisible }
        check(ours.isEmpty, "shows no window of its own at launch (found \(ours.count))")

        showSettings(nil)
        await settle()
        check(window?.isVisible == true, "Settings opens the window")
        check(navigation.destination == .settings(.general), "…on the General pane")
        let windows = NSApp.windows.filter { $0.canBecomeMain && $0.isVisible }.count
        check(windows == 1, "…and it is the only window (found \(windows))")
        await hold("general")

        navigation.show(.performance)
        await settle()
        await hold("performance")

        showAbout(nil)
        await settle()
        check(navigation.destination == .settings(.about), "About goes to the About pane")

        showLibrary(nil)
        await settle()
        check(navigation.destination.isLibrary, "Library goes back to the library")
        await hold("library")

        // The shortcuts, through the real dispatch. Whether the window can become key depends
        // on the OS granting activation to a process launched from a terminal, so that is
        // reported rather than assumed.
        // ⌘W closes the *key* window, so it can only be tested while ours is key. Another app
        // taking focus mid-test is the environment, not a defect, and is reported as such.
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await settle()
        if window?.isKeyWindow == true {
            if let close = command("w", keyCode: 13) { NSApp.sendEvent(close) }
            await settle()
            check(window?.isVisible == false, "⌘W closes the window with no menu bar showing")
        } else {
            print("selftest: skip ⌘W — another app holds focus, so the window cannot be key")
            window?.performClose(nil)
            await settle()
        }

        if let settings = command(",", keyCode: 43) { NSApp.sendEvent(settings) }
        await settle()
        check(window?.isVisible == true && !navigation.destination.isLibrary,
              "⌘, opens Settings with no window open")

        window?.performClose(nil)
        await settle()
        print("selftest: \(failures == 0 ? "PASSED" : "FAILED (\(failures))")")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
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
}

extension AppDelegate: NSWindowDelegate {
    /// Hand focus back to whatever the user was doing before they opened the window.
    ///
    /// A background app with no window left open is still the active app until something else
    /// is clicked, so keystrokes would go nowhere. Deactivating returns them to the previous
    /// app, the way closing a menu bar utility's window is expected to behave.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.deactivate() }
    }
}
