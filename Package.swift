// swift-tools-version: 6.2
// 6.2 is the minimum that exposes SupportedPlatform.MacOSVersion.v26.
import PackageDescription

// macOS 26 is required, not merely preferred: CATapDescription.bundleIDs and the
// whole SpeechAnalyzer / SpeechTranscriber API are API_AVAILABLE(macos(26.0)).
let package = Package(
    name: "Splitvox",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Global hotkey registration plus a recorder control for the settings
        // window. A menu bar crowded enough to hide the status item makes the
        // menu an unreliable way to start a recording mid-meeting.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Splitvox",
            dependencies: ["KeyboardShortcuts"],
            path: "Sources/Splitvox",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SplitvoxTests",
            dependencies: ["Splitvox"],
            path: "Tests/SplitvoxTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
