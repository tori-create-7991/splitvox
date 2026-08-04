import Testing
@testable import Splitvox

/// The sampling itself reads the live system, but the decision it encodes is
/// worth pinning: which combinations record and which do not.
@Suite("MeetingDetector.Sample")
struct MeetingDetectorSampleTests {

    @Test("A headset with audio playing records")
    func headsetWithAudioRecords() {
        let sample = MeetingDetector.Sample(headsetActive: true, playing: ["us.zoom.xos"])

        #expect(sample.shouldRecord)
    }

    /// Wearing a headset while nothing plays is someone about to start work.
    /// Recording then would fill the disk with silence.
    @Test("A headset with nothing playing does not record")
    func headsetWithoutAudioDoesNotRecord() {
        let sample = MeetingDetector.Sample(headsetActive: true, playing: [])

        #expect(sample.shouldRecord == false)
    }

    /// Audio on the built-in speakers is not a call the user is taking; a
    /// headset user is by definition not listening through them.
    @Test("Audio without a headset does not record")
    func audioWithoutHeadsetDoesNotRecord() {
        let sample = MeetingDetector.Sample(headsetActive: false, playing: ["com.google.Chrome"])

        #expect(sample.shouldRecord == false)
    }

    @Test("Neither condition does not record")
    func neitherConditionDoesNotRecord() {
        #expect(MeetingDetector.Sample(headsetActive: false, playing: []).shouldRecord == false)
    }

    /// A video with a headset on is recorded on purpose: the user asked for
    /// that rather than for meeting-only detection.
    @Test("A video played through a headset is recorded, not filtered out")
    func videoThroughHeadsetIsRecorded() {
        let sample = MeetingDetector.Sample(
            headsetActive: true,
            playing: ["com.google.Chrome.helper"]
        )

        #expect(sample.shouldRecord)
    }
}
