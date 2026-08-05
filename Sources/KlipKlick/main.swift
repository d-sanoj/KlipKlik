import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate

// .accessory keeps KlipKlick out of the Dock and the ⌘Tab switcher; it lives in
// the status bar only. `LSUIElement` in Info.plist does the same for the bundled
// app — this covers running the binary directly too.
application.setActivationPolicy(.accessory)
application.run()
