import AppKit
import Foundation

// DIORAMA_RENDER_GUI=<dir> draws the interface to PNGs and exits, so layout can be checked
// without a running Mac and without Screen Recording permission.
if let output = ProcessInfo.processInfo.environment["DIORAMA_RENDER_GUI"] {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        GUIPreviewRenderer.renderAll(to: URL(fileURLWithPath: output))
    }
    exit(0)
}


// A menu bar app: no Dock icon, no main window at launch. `.accessory` rather than `.prohibited`
// so the app can still show settings and library windows when the user asks for them.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
