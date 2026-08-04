import Testing
@testable import Splitvox

@Suite("MeetingTrigger")
struct MeetingTriggerTests {

    private func trigger() -> MeetingTrigger {
        MeetingTrigger(startAfter: 5, stopAfter: 30)
    }

    @Test("A brief burst of meeting audio does not start a recording")
    func briefBurstDoesNotStart() {
        var trigger = trigger()

        #expect(trigger.observe(meetingDetected: true, at: 0) == .none)
        #expect(trigger.observe(meetingDetected: true, at: 3) == .none)
    }

    @Test("Sustained meeting conditions start a recording once the delay passes")
    func sustainedConditionsStart() {
        var trigger = trigger()

        _ = trigger.observe(meetingDetected: true, at: 0)

        #expect(trigger.observe(meetingDetected: true, at: 5) == .start)
    }

    @Test("Starting happens once, not on every later sample")
    func startingHappensOnce() {
        var trigger = trigger()
        _ = trigger.observe(meetingDetected: true, at: 0)
        _ = trigger.observe(meetingDetected: true, at: 5)

        #expect(trigger.observe(meetingDetected: true, at: 6) == .none)
        #expect(trigger.observe(meetingDetected: true, at: 100) == .none)
    }

    /// People pause. Stopping the moment audio drops would cut a meeting into
    /// fragments, so the stop delay is much longer than the start delay.
    @Test("A pause shorter than the stop delay does not stop the recording")
    func shortPauseDoesNotStop() {
        var trigger = trigger()
        _ = trigger.observe(meetingDetected: true, at: 0)
        _ = trigger.observe(meetingDetected: true, at: 5)

        #expect(trigger.observe(meetingDetected: false, at: 10) == .none)
        #expect(trigger.observe(meetingDetected: false, at: 30) == .none)
    }

    @Test("A pause longer than the stop delay stops the recording")
    func longPauseStops() {
        var trigger = trigger()
        _ = trigger.observe(meetingDetected: true, at: 0)
        _ = trigger.observe(meetingDetected: true, at: 5)
        _ = trigger.observe(meetingDetected: false, at: 10)

        #expect(trigger.observe(meetingDetected: false, at: 40) == .stop)
    }

    @Test("Conditions returning during a pause cancels the pending stop")
    func returningConditionsCancelPendingStop() {
        var trigger = trigger()
        _ = trigger.observe(meetingDetected: true, at: 0)
        _ = trigger.observe(meetingDetected: true, at: 5)
        _ = trigger.observe(meetingDetected: false, at: 10)
        _ = trigger.observe(meetingDetected: true, at: 20)

        // 40s is past the original pause, but the pause was cancelled at 20s.
        #expect(trigger.observe(meetingDetected: true, at: 40) == .none)
        #expect(trigger.observe(meetingDetected: false, at: 45) == .none)
    }

    @Test("A gap before starting resets the countdown rather than accumulating")
    func gapBeforeStartingResetsCountdown() {
        var trigger = trigger()
        _ = trigger.observe(meetingDetected: true, at: 0)
        _ = trigger.observe(meetingDetected: false, at: 3)
        _ = trigger.observe(meetingDetected: true, at: 4)

        // Without a reset this would have accumulated past 5s already.
        #expect(trigger.observe(meetingDetected: true, at: 6) == .none)
        #expect(trigger.observe(meetingDetected: true, at: 9) == .start)
    }

    @Test("After stopping, a new meeting can start again")
    func canStartAgainAfterStopping() {
        var trigger = trigger()
        _ = trigger.observe(meetingDetected: true, at: 0)
        _ = trigger.observe(meetingDetected: true, at: 5)
        _ = trigger.observe(meetingDetected: false, at: 10)
        _ = trigger.observe(meetingDetected: false, at: 40)

        _ = trigger.observe(meetingDetected: true, at: 100)

        #expect(trigger.observe(meetingDetected: true, at: 105) == .start)
    }

    /// The user may have started or stopped recording from the menu; the
    /// trigger must not fight that.
    @Test("External state changes are adopted instead of being overridden")
    func externalStateChangesAreAdopted() {
        var trigger = trigger()

        trigger.recordingBecameActive(at: 0)
        // Already recording, so sustained conditions must not re-issue a start.
        _ = trigger.observe(meetingDetected: true, at: 1)
        #expect(trigger.observe(meetingDetected: true, at: 10) == .none)

        trigger.recordingBecameInactive(at: 20)
        _ = trigger.observe(meetingDetected: true, at: 21)
        #expect(trigger.observe(meetingDetected: true, at: 26) == .start)
    }
}
