import Foundation

/// Decides when observed audio activity should start or stop a recording.
///
/// Pure timing logic, separated from the sampling so it can be tested without
/// waiting in real time or holding a microphone open.
///
/// The two delays are deliberately asymmetric. Starting waits only a few
/// seconds, because the cost of a late start is lost meeting. Stopping waits
/// much longer, because people pause: reacting to every silence would chop one
/// meeting into a pile of fragments.
struct MeetingTrigger {

    enum Action: Equatable {
        case none
        case start
        case stop
    }

    let startAfter: TimeInterval
    let stopAfter: TimeInterval

    private var isRecording = false
    /// When the current run of matching samples began, or nil if the latest
    /// sample broke the run.
    private var detectedSince: TimeInterval?
    private var absentSince: TimeInterval?

    init(startAfter: TimeInterval = 5, stopAfter: TimeInterval = 30) {
        self.startAfter = startAfter
        self.stopAfter = stopAfter
    }

    mutating func observe(meetingDetected: Bool, at now: TimeInterval) -> Action {
        if meetingDetected {
            absentSince = nil
            let since = detectedSince ?? now
            detectedSince = since

            guard !isRecording, now - since >= startAfter else { return .none }
            isRecording = true
            return .start
        }

        detectedSince = nil
        let since = absentSince ?? now
        absentSince = since

        guard isRecording, now - since >= stopAfter else { return .none }
        isRecording = false
        return .stop
    }

    /// Adopt a recording that something else began — the menu, or the hotkey —
    /// so the trigger does not try to start one on top of it.
    mutating func recordingBecameActive(at now: TimeInterval) {
        isRecording = true
        detectedSince = now
        absentSince = nil
    }

    mutating func recordingBecameInactive(at now: TimeInterval) {
        isRecording = false
        detectedSince = nil
        absentSince = now
    }
}
