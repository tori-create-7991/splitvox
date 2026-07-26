// swift-tools-version: 6.2
// 6.2 is the minimum that exposes SupportedPlatform.MacOSVersion.v26.
import PackageDescription

// macOS 26 is required, not merely preferred: CATapDescription.bundleIDs and the
// whole SpeechAnalyzer / SpeechTranscriber API are API_AVAILABLE(macos(26.0)).
let package = Package(
    name: "Splitvox",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Splitvox",
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
