import AppKit
import Metal
import WallpaperKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = DisplayCoordinator()
    private var statusItem: NSStatusItem?
    private var renderers: [CGDirectDisplayID: GradientRenderer] = [:]
    private var device: MTLDevice?
    private let log = Logger(subsystem: "app.diorama", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            log.critical("no Metal device; this Mac cannot run Diorama")
            NSApp.terminate(nil)
            return
        }
        self.device = device
        log.info("Metal device: \(device.name, privacy: .public), BC textures: \(device.supportsBCTextureCompression)")

        setUpStatusItem()

        coordinator.onSurfaceAdded = { [weak self] surface in
            guard let self, let device = self.device else { return }
            surface.mountMetalLayer()
            self.renderers[surface.displayID] = GradientRenderer(device: device)
            surface.onFrame = { [weak self, weak surface] _ in
                guard let self, let surface, let layer = surface.metalLayer else { return }
                self.renderers[surface.displayID]?.render(to: layer)
            }
            // The scaffolding gradient always has something to draw; a real backend reports this
            // when content is actually assigned to the display.
            self.coordinator.setHasContent(true, frameRate: nil, for: surface.displayID)
        }

        coordinator.onSurfaceRemoved = { [weak self] displayID in
            self?.renderers.removeValue(forKey: displayID)
        }

        // DIORAMA_FORCE_RENDER=1 disables occlusion suspension so the render path can be
        // measured without physically clearing every window off the desktop. Diagnostics only.
        if ProcessInfo.processInfo.environment["DIORAMA_FORCE_RENDER"] == "1" {
            var preferences = PowerPreferences.default
            preferences.suspendWhenOccluded = false
            preferences.suspendUnderFullscreenApps = false
            preferences.suspendInLowPowerMode = false
            coordinator.setPreferences(preferences)
            log.warning("DIORAMA_FORCE_RENDER is set; occlusion suspension disabled")
        }

        coordinator.start()
        log.info("started with \(self.coordinator.surfaces.count) surface(s)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
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

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = MenuTag.status.rawValue
        menu.addItem(status)

        menu.addItem(.separator())

        let pause = NSMenuItem(
            title: "Pause Wallpapers",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pause.target = self
        pause.tag = MenuTag.pause.rawValue
        menu.addItem(pause)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Diorama", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private enum MenuTag: Int {
        case status = 1
        case pause = 2
    }

    @objc private func togglePause() {
        coordinator.policy.isUserPaused.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Refresh the live readout only while the menu is actually open. Updating it on a timer
    /// would mean doing work every second to describe how little work we are doing.
    func menuWillOpen(_ menu: NSMenu) {
        if let item = menu.item(withTag: MenuTag.status.rawValue) {
            item.title = statusSummary()
        }
        if let item = menu.item(withTag: MenuTag.pause.rawValue) {
            item.title = coordinator.policy.isUserPaused ? "Resume Wallpapers" : "Pause Wallpapers"
        }
    }

    private func statusSummary() -> String {
        let displays = coordinator.surfaces.count
        guard displays > 0 else { return "No displays" }

        let running = coordinator.surfaces.values.filter { !$0.directive.isSuspended }
        if running.isEmpty {
            let reason = coordinator.surfaces.values.first?.directive
            if case .suspended(let why) = reason {
                return "Idle — \(why.description)"
            }
            return "Idle"
        }
        let fps = running.map(\.directive.frameRate).max() ?? 0
        let gpu = renderers.values.map(\.lastGPUMilliseconds).max() ?? 0
        return String(
            format: "%d of %d display%@ · %dfps · %.2fms GPU",
            running.count, displays, displays == 1 ? "" : "s", fps, gpu
        )
    }
}
