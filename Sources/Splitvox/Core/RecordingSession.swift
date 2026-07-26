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

    /// Status-bar title for the current state. Owned here rather than in
    /// `AppDelegate` so the mapping is covered by tests.
    var statusTitle: String {
        switch state {
        case .idle: return "●"
        case .recording: return "⏺"
        case .transcribing: return "⋯"
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
