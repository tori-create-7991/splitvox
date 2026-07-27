import AppKit

// Diagnostics run headless and exit; they must not start the menu bar app.
if CommandLine.arguments.contains("--probe-tap") {
    ProbeCommand.run(bundleIDs: Config.defaultMeetingBundleIDs)
    exit(0)
}

if CommandLine.arguments.contains("--probe-aggregate") {
    ProbeCommand.probeAggregate(
        bundleIDs: Config.defaultMeetingBundleIDs,
        preferredInputUID: nil
    )
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--probe-transcribe") {
    let directory = CommandLine.arguments.dropFirst(index + 1).first.map {
        URL(fileURLWithPath: $0)
    } ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("splitvox-probe", isDirectory: true)

    // Top-level code cannot await, so the async probe is driven to completion
    // before the process exits.
    let done = DispatchSemaphore(value: 0)
    Task {
        await ProbeCommand.probeTranscribe(directory: directory)
        done.signal()
    }
    done.wait()
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--probe-record") {
    let seconds = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Double.init) ?? 20
    ProbeCommand.probeRecord(
        bundleIDs: Config.defaultMeetingBundleIDs,
        preferredInputUID: nil,
        seconds: seconds,
        outputDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("splitvox-probe", isDirectory: true)
    )
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
