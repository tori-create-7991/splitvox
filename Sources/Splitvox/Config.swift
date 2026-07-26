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

    /// Transcription locale. SpeechTranscriber lists ja_JP in supportedLocales.
    static let transcriptionLocaleIdentifier = "ja-JP"

    static let recordingsDirectoryName = "Recordings"
    static let applicationSupportDirectoryName = "Splitvox"
}
