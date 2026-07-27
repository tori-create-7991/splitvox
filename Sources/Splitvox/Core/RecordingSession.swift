import Foundation

enum RecordingState: Equatable {
    case idle
    case recording
    case transcribing
}

/// The recording lifecycle, extracted from `AppDelegate` so the transitions can
/// be tested without AppKit, Core Audio, or a real meeting.
///
/// Transitions return `false` rather than throwing: every rejection here comes
/// from a menu item being clicked in a state that does not allow it, which is a
/// no-op for the user, not an error worth surfacing.
struct RecordingSession: Equatable {
    private(set) var state: RecordingState = .idle
    private(set) var lastErrorMessage: String?

    /// SF Symbol shown in the status bar. Owned here rather than in
    /// `AppDelegate` so the mapping is covered by tests.
    ///
    /// Symbols rather than text characters because a menu bar with many items
    /// makes a plain "●" indistinguishable from its neighbours.
    var statusSymbolName: String {
        switch state {
        case .idle: return "waveform"
        case .recording: return "record.circle.fill"
        case .transcribing: return "waveform.badge.clock"
        }
    }

    /// Spoken by VoiceOver, and also what identifies this item in the menu bar
    /// listings that otherwise show every third-party item as "status menu".
    var accessibilityDescription: String {
        switch state {
        case .idle: return "Splitvox — 待機中"
        case .recording: return "Splitvox — 録音中"
        case .transcribing: return "Splitvox — 文字起こし中"
        }
    }

    mutating func start() -> Bool {
        guard state == .idle else { return false }
        state = .recording
        lastErrorMessage = nil
        return true
    }

    mutating func stop() -> Bool {
        guard state == .recording else { return false }
        state = .transcribing
        return true
    }

    mutating func finish() -> Bool {
        guard state == .transcribing else { return false }
        state = .idle
        return true
    }

    /// Abandon the session from any state. Recording and transcription both run
    /// against hardware and on-device models that can fail mid-flight, so every
    /// state needs a way back to idle without losing the reason.
    mutating func fail(_ message: String) {
        state = .idle
        lastErrorMessage = message
    }
}
