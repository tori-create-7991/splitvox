import Testing
@testable import Splitvox

// `#expect` re-evaluates the expression it captures, so a mutating call cannot
// be passed to it directly. Every transition result is bound first.
@Suite("RecordingSession")
struct RecordingSessionTests {

    @Test("A new session is idle")
    func newSessionIsIdle() {
        #expect(RecordingSession().state == .idle)
    }

    @Test("Starting from idle begins recording")
    func startingFromIdleBeginsRecording() {
        var session = RecordingSession()

        let started = session.start()

        #expect(started)
        #expect(session.state == .recording)
    }

    @Test("Stopping a recording moves to transcribing")
    func stoppingARecordingMovesToTranscribing() {
        var session = RecordingSession()
        _ = session.start()

        let stopped = session.stop()

        #expect(stopped)
        #expect(session.state == .transcribing)
    }

    @Test("Finishing transcription returns to idle")
    func finishingTranscriptionReturnsToIdle() {
        var session = RecordingSession()
        _ = session.start()
        _ = session.stop()

        let finished = session.finish()

        #expect(finished)
        #expect(session.state == .idle)
    }

    @Test("Starting while already recording is rejected and leaves the state untouched")
    func startingWhileRecordingIsRejected() {
        var session = RecordingSession()
        _ = session.start()

        let startedAgain = session.start()

        #expect(startedAgain == false)
        #expect(session.state == .recording)
    }

    @Test("Stopping while idle is rejected and leaves the state untouched")
    func stoppingWhileIdleIsRejected() {
        var session = RecordingSession()

        let stopped = session.stop()

        #expect(stopped == false)
        #expect(session.state == .idle)
    }

    @Test("Finishing while not transcribing is rejected")
    func finishingWhileNotTranscribingIsRejected() {
        var session = RecordingSession()
        _ = session.start()

        let finished = session.finish()

        #expect(finished == false)
        #expect(session.state == .recording)
    }

    @Test("Failing from any state returns to idle and retains the reason")
    func failingReturnsToIdleAndRetainsReason() {
        var recording = RecordingSession()
        _ = recording.start()
        recording.fail("タップの作成に失敗しました")

        #expect(recording.state == .idle)
        #expect(recording.lastErrorMessage == "タップの作成に失敗しました")

        var transcribing = RecordingSession()
        _ = transcribing.start()
        _ = transcribing.stop()
        transcribing.fail("日本語モデルが利用できません")

        #expect(transcribing.state == .idle)
        #expect(transcribing.lastErrorMessage == "日本語モデルが利用できません")
    }

    @Test("Starting a new recording clears the previous failure")
    func startingClearsPreviousFailure() {
        var session = RecordingSession()
        session.fail("前回の失敗")

        let started = session.start()

        #expect(started)
        #expect(session.lastErrorMessage == nil)
    }

    @Test("The status item symbol reflects the state")
    func statusSymbolReflectsState() {
        var session = RecordingSession()
        #expect(session.statusSymbolName == "waveform")

        _ = session.start()
        #expect(session.statusSymbolName == "record.circle.fill")

        _ = session.stop()
        #expect(session.statusSymbolName == "waveform.badge.clock")

        _ = session.finish()
        #expect(session.statusSymbolName == "waveform")
    }

    @Test("Every state names itself for accessibility and menu bar listings")
    func everyStateHasAnAccessibilityDescription() {
        var session = RecordingSession()
        var descriptions: [String] = [session.accessibilityDescription]

        _ = session.start()
        descriptions.append(session.accessibilityDescription)

        _ = session.stop()
        descriptions.append(session.accessibilityDescription)

        #expect(descriptions.allSatisfy { $0.contains("Splitvox") })
        #expect(Set(descriptions).count == 3)
    }
}
