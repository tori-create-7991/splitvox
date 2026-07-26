import AppKit

// Menu-bar-only app: no Dock icon, no Cmd+Tab entry.
// Program entry runs on the main thread == the main actor.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
