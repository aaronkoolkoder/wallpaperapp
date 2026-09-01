import AppKit

// A menu bar app: no Dock icon, no main window at launch. `.accessory` rather than `.prohibited`
// so the app can still show settings and library windows when the user asks for them.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
