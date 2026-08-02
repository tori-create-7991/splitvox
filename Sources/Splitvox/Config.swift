import Foundation

/// Build-time constants. Anything the user can change lives in `Storage/`.
enum Config {
    static let bundleIdentifier = "com.ryo.splitvox"

    /// Applications whose output audio is captured by the process tap.
    ///
    /// Chrome plays audio from a helper process registered under its own bundle
    /// ID, so the parent alone may carry no audio. Listing several identifiers
    /// is free — a silent application contributes silence. Run
    /// `swift Tools/audio-process-watch.swift` to confirm the right values on a
    /// given machine.
    static let defaultMeetingBundleIDs = [
        "com.google.Chrome",
        "com.google.Chrome.helper"
    ]

    /// A meeting application and the bundle IDs that actually emit its audio.
    struct MeetingApp: Identifiable, Equatable {
        let name: String
        let bundleIDs: [String]
        var id: String { name }
    }

    /// Presets offered in Settings.
    ///
    /// Several of these route audio through a helper process with its own
    /// bundle ID, which is why each entry is a list. Only Chrome, Zoom and
    /// Safari were verified on the development machine — the rest are best
    /// guesses, which is exactly why Settings can also detect the bundle ID of
    /// whatever is currently making sound.
    static let knownMeetingApps: [MeetingApp] = [
        MeetingApp(
            name: "Google Chrome（Meet ほか）",
            bundleIDs: ["com.google.Chrome", "com.google.Chrome.helper"]
        ),
        // Verified on disk: Zoom ships ten nested applications. The meeting
        // audio comes from the host processes, not from us.zoom.xos itself.
        MeetingApp(
            name: "Zoom",
            bundleIDs: [
                "us.zoom.xos",
                "us.zoom.CptHost",
                "us.zoom.caphost",
                "us.zoom.aomhost",
                "us.zoom.airhost"
            ]
        ),
        MeetingApp(name: "Safari", bundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU"]),
        MeetingApp(
            name: "Microsoft Teams",
            bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]
        ),
        MeetingApp(name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"]),
        MeetingApp(name: "Discord", bundleIDs: ["com.hnc.Discord"]),
        MeetingApp(name: "Webex", bundleIDs: ["Cisco-Systems.Spark"]),
        MeetingApp(name: "Firefox", bundleIDs: ["org.mozilla.firefox"]),
        MeetingApp(name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"]),
        MeetingApp(name: "Arc", bundleIDs: ["company.thebrowser.Browser"]),
        // LINE runs calls in a separate bundled application. Only the parent is
        // registered with Core Audio until a call actually starts, so both have
        // to be listed up front.
        MeetingApp(
            name: "LINE",
            bundleIDs: ["jp.naver.line.mac", "jp.naver.line.mac.LineCall"]
        )
    ]

    /// Transcription locale. SpeechTranscriber lists ja_JP in supportedLocales.
    static let transcriptionLocaleIdentifier = "ja-JP"

    static let recordingsDirectoryName = "Recordings"
    static let applicationSupportDirectoryName = "Splitvox"
}
