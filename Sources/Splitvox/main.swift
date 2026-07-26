import AppKit

// Diagnostics run headless and exit; they must not start the menu bar app.
if CommandLine.arguments.contains("--probe-tap") {
    ProbeCommand.run(bundleIDs: Config.defaultMeetingBundleIDs)
    exit(0)
}

// Menu-bar-only app: no Dock icon, no Cmd+Tab entry.
// Program entry runs on the main thread == the main actor.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
