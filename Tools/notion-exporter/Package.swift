// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SplitvoxNotion",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "splitvox-notion", targets: ["SplitvoxNotion"])],
    targets: [
        .executableTarget(name: "SplitvoxNotion", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SplitvoxNotionTests", dependencies: ["SplitvoxNotion"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
