import Foundation

/// Where each side sits inside the aggregate device's interleaved input.
///
/// The aggregate device presents the microphone sub-device and the process tap
/// as separate input streams, concatenated into one channel range. Which comes
/// first is not documented; `Splitvox --probe-aggregate` measured `[1, 2]` on
/// the development machine — sub-device first, tap second — and this type
/// encodes that ordering while still deriving the actual indices from the
/// device rather than hard-coding them.
struct CaptureChannelLayout: Equatable {
    let microphoneChannels: Range<Int>
    let systemAudioChannels: Range<Int>

    var totalChannels: Int { systemAudioChannels.upperBound }

    /// Derive the split from the device's per-stream channel counts.
    ///
    /// Returns `nil` rather than guessing when the device does not look like
    /// the expected microphone-plus-tap pair: a wrong split would silently
    /// write the wrong person's audio into each file, which is worse than
    /// refusing to record.
    static func resolve(streamChannelCounts: [Int]) -> CaptureChannelLayout? {
        guard streamChannelCounts.count == 2 else { return nil }

        let microphoneCount = streamChannelCounts[0]
        let systemAudioCount = streamChannelCounts[1]
        guard microphoneCount > 0, systemAudioCount > 0 else { return nil }

        return CaptureChannelLayout(
            microphoneChannels: 0..<microphoneCount,
            systemAudioChannels: microphoneCount..<(microphoneCount + systemAudioCount)
        )
    }
}
