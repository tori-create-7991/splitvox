import Foundation

/// Build-time constants. Anything the user can change lives in `Storage/`.
enum Config {
    /// A namespace the project actually controls, via the GitHub account.
    ///
    /// macOS does not verify domain ownership, so any string works — but this
    /// one has to be unique per build in practice. TCC keys microphone and
    /// audio-capture consent to the bundle ID plus the signature, and
    /// `UserDefaults.standard` keys its domain to the bundle ID alone. Two
    /// builds sharing an identifier therefore share one permission entry and
    /// one settings store.
    ///
    /// **Forks should change this.** Leaving it means the fork and upstream
    /// cannot both hold their own permissions on the same machine.
    static let bundleIdentifier = "io.github.tori-create-7991.splitvox"

    /// Applications whose output audio is captured by the process tap.
    ///
    /// Deliberately broad. Listing an application that is not running, or is
    /// running silently, costs nothing — it contributes silence. Listing too
    /// few costs a whole meeting: a real 40-minute Zoom call was recorded with
    /// only Chrome configured and the far side came out completely silent, and
    /// that is not discoverable until the recording is over.
    ///
    /// Most of these play audio from a helper process with its own bundle ID,
    /// so the parent alone is not enough. Use Settings → 再生中を検出, or
    /// `--list-apps`, to add anything missing on a given machine.
    static let defaultMeetingBundleIDs = [
        // Browsers — Meet, Teams web, Zoom web, and everything else in a tab.
        "com.google.Chrome",
        "com.google.Chrome.helper",
        "com.apple.Safari",
        "com.apple.WebKit.GPU",

        // Zoom. Meeting audio comes from the host processes, not us.zoom.xos.
        "us.zoom.xos",
        "us.zoom.CptHost",
        "us.zoom.caphost",
        "us.zoom.aomhost",
        "us.zoom.airhost",

        // LINE runs calls in a separate bundled application.
        "jp.naver.line.mac",
        "jp.naver.line.mac.LineCall",

        // Other common meeting clients.
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord"
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

    struct TranscriptionLocale: Sendable {
        let identifier: String
        let label: String
    }

    /// Languages offered in Settings. SpeechTranscriber supports 42 locales;
    /// these are the ones worth surfacing rather than a full list.
    static let transcriptionLocales: [TranscriptionLocale] = [
        TranscriptionLocale(identifier: "ja-JP", label: "日本語"),
        TranscriptionLocale(identifier: "en-US", label: "English (US)"),
        TranscriptionLocale(identifier: "en-GB", label: "English (UK)"),
        TranscriptionLocale(identifier: "zh-CN", label: "中文（簡体）"),
        TranscriptionLocale(identifier: "ko-KR", label: "한국어"),
        TranscriptionLocale(identifier: "de-DE", label: "Deutsch"),
        TranscriptionLocale(identifier: "fr-FR", label: "Français"),
        TranscriptionLocale(identifier: "es-ES", label: "Español")
    ]

    /// Transcription locale. SpeechTranscriber lists ja_JP in supportedLocales.
    static let transcriptionLocaleIdentifier = "ja-JP"

    static let recordingsDirectoryName = "Recordings"
    static let applicationSupportDirectoryName = "Splitvox"
}
