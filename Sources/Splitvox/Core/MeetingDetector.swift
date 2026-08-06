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

    /// Whether a bundle ID falls under an exclusion.
    ///
    /// Case-insensitive: a user typing `Notion.id` must not silently get an
    /// entry that never matches.
    ///
    /// Prefix match on dot boundaries, so excluding `notion.id` also covers
    /// `notion.id.helper` — the helper is usually what plays the notification
    /// chime, and listing every one by hand is not reasonable. The boundary
    /// check keeps `notion.identity.other` from being caught by it.
    static func isExcluded(_ bundleID: String, by excluded: [String]) -> Bool {
        let subject = bundleID.lowercased()
        return excluded.contains { pattern in
            let normalised = pattern.lowercased()
            guard !normalised.isEmpty else { return false }
            return subject == normalised || subject.hasPrefix(normalised + ".")
        }
    }

    /// The include/exclude filtering, separated from the Core Audio calls so it
    /// can be tested. Previously this lived inline and the exclusion filter had
    /// no end-to-end coverage — deleting it failed nothing.
    static func filterPlaying(
        producing: [String],
        configured: [String],
        excluded: [String]
    ) -> [String] {
        Set(producing)
            .intersection(Set(configured))
            .subtracting([Config.bundleIdentifier])
            .filter { !isExcluded($0, by: excluded) }
            .sorted()
    }

    /// Microphone holders that count toward the trigger.
    ///
    /// Exclusions apply here too. Without it, an app the user excluded still
    /// satisfies `.microphoneInUse` — and with `.playback` unchecked that is the
    /// only condition, so Siri or an excluded app would start a recording.
    static func filterCapturing(_ capturing: [String], excluded: [String]) -> [String] {
        capturing
            .filter { $0 != Config.bundleIdentifier }
            .filter { !isExcluded($0, by: excluded) }
            .sorted()
    }

    static func sample(meetingBundleIDs: [String], excludedBundleIDs: [String] = []) -> Sample {
        // Splitvox holds the microphone while recording, so counting itself
        // would make the microphone condition self-sustaining and the recording
        // would never stop.
        let capturing = AudioProcessLookup.bundleIDsConsumingInput(
            excluding: [Config.bundleIdentifier]
        )

        return Sample(
            headsetActive: AudioDeviceLookup.isExternalInputActive(),
            physicalHeadsetActive: AudioDeviceLookup.isPhysicalExternalInputActive(),
            microphoneInUse: !filterCapturing(capturing, excluded: excludedBundleIDs).isEmpty,
            playing: filterPlaying(
                producing: AudioProcessLookup.bundleIDsProducingOutput(),
                configured: meetingBundleIDs,
                excluded: excludedBundleIDs
            )
        )
    }
}
