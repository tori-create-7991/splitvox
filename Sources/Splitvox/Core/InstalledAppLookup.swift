import Foundation

struct InstalledApp: Identifiable, Equatable {
    let name: String
    let bundleID: String
    /// Bundled sub-applications, which is where several apps actually play
    /// audio from: LINE calls run in `LineCall.app`, Zoom meetings in
    /// `CptHost.app`, Chrome media in its helper.
    let helperBundleIDs: [String]

    var id: String { bundleID }
    var allBundleIDs: [String] { [bundleID] + helperBundleIDs }
}

/// Finds installed applications and the bundle IDs they might emit audio under.
///
/// Exists because a hard-coded preset list goes stale and cannot cover what a
/// given machine has installed. Reading the disk answers "what do I put in the
/// bundle ID list" without guessing.
enum InstalledAppLookup {

    private static let searchPaths = [
        "/Applications",
        NSHomeDirectory() + "/Applications"
    ]

    /// Sub-applications that never play meeting audio, skipped to keep the
    /// picker readable.
    private static let ignoredHelperSuffixes = [
        "Uninstaller", "AutoUpdater", "Updater", "Crashpad", "ShipIt", "Screenshot"
    ]

    static func scan() -> [InstalledApp] {
        let manager = FileManager.default
        var apps: [InstalledApp] = []

        for path in searchPaths {
            guard let entries = try? manager.contentsOfDirectory(atPath: path) else { continue }

            for entry in entries where entry.hasSuffix(".app") {
                let appPath = path + "/" + entry
                guard let bundleID = bundleIdentifier(atAppPath: appPath) else { continue }

                apps.append(
                    InstalledApp(
                        name: String(entry.dropLast(4)),
                        bundleID: bundleID,
                        helperBundleIDs: helperBundleIDs(inAppPath: appPath)
                    )
                )
            }
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func bundleIdentifier(atAppPath appPath: String) -> String? {
        guard let plist = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist"),
              let identifier = plist["CFBundleIdentifier"] as? String,
              !identifier.isEmpty else { return nil }
        return identifier
    }

    /// Nested `.app` bundles under Frameworks / Helpers / XPCServices.
    ///
    /// Chrome's audio helper is not reachable this way — it shares the parent's
    /// Helpers directory but registers as `com.google.Chrome.helper` at
    /// runtime — so this complements, rather than replaces, reading the live
    /// process list.
    private static func helperBundleIDs(inAppPath appPath: String) -> [String] {
        let manager = FileManager.default
        var found: [String] = []

        let containers = [
            "/Contents/Frameworks",
            "/Contents/Helpers",
            "/Contents/Library/LoginItems"
        ]

        for container in containers {
            let directory = appPath + container
            guard let entries = try? manager.contentsOfDirectory(atPath: directory) else { continue }

            for entry in entries where entry.hasSuffix(".app") {
                let name = String(entry.dropLast(4))
                guard !ignoredHelperSuffixes.contains(where: { name.hasSuffix($0) }) else { continue }
                guard let identifier = bundleIdentifier(atAppPath: directory + "/" + entry) else { continue }
                found.append(identifier)
            }
        }

        return found
    }
}
