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
    /// Upper bound on one recording.
    ///
    /// A real guard, not file rotation: after the cap fires, the trigger will
    /// not start again until the conditions have actually lapsed once. Without
    /// that latch an application left playing simply restarts the countdown and
    /// fills the disk in 4-hour instalments, which is what the cap exists to
    /// prevent.
    ///
    /// Measured against `systemUptime`, which does not advance while the Mac
    /// sleeps — so this bounds awake time, not wall time.
    let maximumDuration: TimeInterval

    private var isRecording = false
    /// When the current run of matching samples began, or nil if the latest
    /// sample broke the run.
    private var detectedSince: TimeInterval?
    private var absentSince: TimeInterval?
    private var recordingSince: TimeInterval?
    /// Set when the cap fires. Blocks restarting until conditions go false.
    private var awaitingConditionsToLapse = false

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
            awaitingConditionsToLapse = true
            return .stop
        }

        if meetingDetected {
            absentSince = nil
            let since = detectedSince ?? now
            detectedSince = since

            guard !awaitingConditionsToLapse else { return .none }
            guard !isRecording, now - since >= startAfter else { return .none }
            isRecording = true
            recordingSince = now
            return .start
        }

        detectedSince = nil
        // Conditions have lapsed, so a cap-triggered block is lifted.
        awaitingConditionsToLapse = false
        let since = absentSince ?? now
        absentSince = since

        guard isRecording, now - since >= stopAfter else { return .none }
        isRecording = false
        recordingSince = nil
        return .stop
    }

    /// Replace the thresholds without losing the run state.
    ///
    /// Assigning a whole new trigger would discard `isRecording` and
    /// `recordingSince`, so closing the settings window mid-recording would
    /// restart the cap clock — or, with auto-record switched off, leave the
    /// running recording with no cap at all.
    func adopting(timing: AutoRecordTiming) -> MeetingTrigger {
        var updated = MeetingTrigger(timing: timing)
        updated.isRecording = isRecording
        updated.recordingSince = recordingSince
        updated.detectedSince = detectedSince
        updated.absentSince = absentSince
        updated.awaitingConditionsToLapse = awaitingConditionsToLapse
        return updated
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

    /// Exposed for tests and for `adopting(timing:)`.
    var isCurrentlyRecording: Bool { isRecording }
}
