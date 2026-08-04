import Foundation

/// Samples the running system for signs that something worth recording is
/// happening.
///
/// The signal is a headset plus audio playing, not "a meeting app is holding
/// the microphone". Putting on a headset is a deliberate act that precedes a
/// call, it happens *before* anyone speaks, and it does not depend on guessing
/// which application counts as a meeting. Recording a video with it on is
/// acceptable — a transcript of something you chose to listen to is not a
/// failure.
///
/// Playback is still required so that simply wearing a headset in silence does
/// not fill the disk. It is restricted to configured applications because the
/// tap only captures those: anything else would record an empty far side.
enum MeetingDetector {

    struct Sample {
        let headsetActive: Bool
        let playing: [String]

        /// Both conditions together. A headset alone is someone about to work;
        /// playback alone is the speakers, which a headset user is not using.
        var shouldRecord: Bool { headsetActive && !playing.isEmpty }
    }

    static func sample(meetingBundleIDs: [String]) -> Sample {
        let configured = Set(meetingBundleIDs)

        // Splitvox itself plays nothing, but excluding it keeps the signal
        // honest if that ever changes.
        let excluded: Set<String> = [Config.bundleIdentifier]

        let playing = Set(AudioProcessLookup.bundleIDsProducingOutput())
            .intersection(configured)
            .subtracting(excluded)

        return Sample(
            headsetActive: AudioDeviceLookup.isExternalInputActive(),
            playing: playing.sorted()
        )
    }
}
