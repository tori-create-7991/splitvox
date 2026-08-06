import Foundation

/// Samples the running system for signs that something worth recording is
/// happening.
///
/// Collects every signal on each pass and lets the chosen condition decide,
/// rather than baking one rule in. Which signal is right depends on the person:
/// a headset is a deliberate act that happens before anyone speaks, but it
/// cannot distinguish a real headset from a virtual audio device, and requiring
/// the microphone is stricter at the cost of missing the opening.
enum MeetingDetector {

    struct Sample {
        let headsetActive: Bool
        let physicalHeadsetActive: Bool
        let microphoneInUse: Bool
        let playing: [String]

        /// Every enabled condition must hold. More conditions means stricter.
        ///
        /// An empty set means the trigger is off, not that everything matches —
        /// a set with no constraints would start recording and never stop.
        func shouldRecord(matching conditions: AutoRecordConditions) -> Bool {
            guard !conditions.isEmpty else { return false }

            if conditions.contains(.playback) && playing.isEmpty { return false }
            if conditions.contains(.externalInput) && !headsetActive { return false }
            if conditions.contains(.physicalInput) && !physicalHeadsetActive { return false }
            if conditions.contains(.microphoneInUse) && !microphoneInUse { return false }

            return true
        }
    }

    static func sample(meetingBundleIDs: [String]) -> Sample {
        let configured = Set(meetingBundleIDs)

        // Splitvox holds the microphone while recording, so counting itself
        // would make the microphone condition self-sustaining and the recording
        // would never stop.
        let excluded: Set<String> = [Config.bundleIdentifier]

        let playing = Set(AudioProcessLookup.bundleIDsProducingOutput())
            .intersection(configured)
            .subtracting(excluded)

        let capturing = AudioProcessLookup.bundleIDsConsumingInput(excluding: excluded)

        return Sample(
            headsetActive: AudioDeviceLookup.isExternalInputActive(),
            physicalHeadsetActive: AudioDeviceLookup.isPhysicalExternalInputActive(),
            microphoneInUse: !capturing.isEmpty,
            playing: playing.sorted()
        )
    }
}
