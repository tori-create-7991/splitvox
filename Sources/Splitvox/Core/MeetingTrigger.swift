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
    /// Upper bound on one recording, as a runaway guard. An application left
    /// playing would otherwise record until the disk fills.
    let maximumDuration: TimeInterval

    private var isRecording = false
    /// When the current run of matching samples began, or nil if the latest
    /// sample broke the run.
    private var detectedSince: TimeInterval?
    private var absentSince: TimeInterval?
    private var recordingSince: TimeInterval?

    init(
        startAfter: TimeInterval = 5,
        stopAfter: TimeInterval = 30,
        maximumDuration: TimeInterval = 4 * 60 * 60
    ) {
        self.startAfter = startAfter
        self.stopAfter = stopAfter
        self.maximumDuration = maximumDuration
    }

    init(timing: AutoRecordTiming) {
        self.init(
            startAfter: timing.startAfter,
            stopAfter: timing.stopAfter,
            maximumDuration: timing.maximumDuration
        )
    }

    mutating func observe(meetingDetected: Bool, at now: TimeInterval) -> Action {
        // The cap is checked first: conditions that never lapse must not be
        // able to hold a recording open indefinitely.
        if isRecording, let since = recordingSince, now - since >= maximumDuration {
            isRecording = false
            recordingSince = nil
            detectedSince = nil
            absentSince = now
            return .stop
        }

        if meetingDetected {
            absentSince = nil
            let since = detectedSince ?? now
            detectedSince = since

            guard !isRecording, now - since >= startAfter else { return .none }
            isRecording = true
            recordingSince = now
            return .start
        }

        detectedSince = nil
        let since = absentSince ?? now
        absentSince = since

        guard isRecording, now - since >= stopAfter else { return .none }
        isRecording = false
        recordingSince = nil
        return .stop
    }

    /// Adopt a recording that something else began — the menu, or the hotkey —
    /// so the trigger does not try to start one on top of it.
    mutating func recordingBecameActive(at now: TimeInterval) {
        isRecording = true
        recordingSince = now
        detectedSince = now
        absentSince = nil
    }

    mutating func recordingBecameInactive(at now: TimeInterval) {
        isRecording = false
        recordingSince = nil
        detectedSince = nil
        absentSince = now
    }
}
