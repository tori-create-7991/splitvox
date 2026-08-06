import Foundation

/// Timing and level thresholds for the automatic trigger.
///
/// Previously hard-coded. They are exposed because the right values depend on
/// how a meeting actually runs: a discussion with long pauses needs a longer
/// stop delay than a status call, and neither value is knowable in advance.
struct AutoRecordTiming: Equatable {

    /// How long the conditions must hold before recording starts.
    ///
    /// Short by default. A late start loses the opening of a meeting, which
    /// cannot be recovered; a slightly early start costs a few seconds of disk.
    var startAfter: TimeInterval

    /// How long the conditions must fail before recording stops.
    ///
    /// Much longer than `startAfter` on purpose. People pause, and reacting to
    /// every silence would cut one meeting into a pile of fragments.
    var stopAfter: TimeInterval

    /// Upper bound on a single recording, as a runaway guard.
    ///
    /// Without it, an application left playing audio can record until the disk
    /// fills — roughly a gigabyte an hour.
    var maximumDuration: TimeInterval

    /// Level below which playback is treated as silence, in dBFS.
    ///
    /// `IsRunningOutput` is a boolean and says nothing about loudness, so a
    /// notification chirp counts the same as a meeting. This ignores anything
    /// quieter than the threshold.
    var playbackThresholdDecibels: Double

    static let `default` = AutoRecordTiming(
        startAfter: 5,
        stopAfter: 30,
        maximumDuration: 4 * 60 * 60,
        playbackThresholdDecibels: -50
    )

    static let startChoices: [TimeInterval] = [0, 3, 5, 10, 30]
    static let stopChoices: [TimeInterval] = [10, 30, 60, 120, 300]
    static let maximumChoices: [TimeInterval] = [30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60, 8 * 60 * 60]
    static let thresholdChoices: [Double] = [-70, -60, -50, -40, -30]

    static func describeSeconds(_ value: TimeInterval) -> String {
        if value == 0 { return "すぐに" }
        if value < 60 { return "\(Int(value)) 秒" }
        if value < 3600 { return "\(Int(value / 60)) 分" }
        return "\(Int(value / 3600)) 時間"
    }

    static func describeThreshold(_ value: Double) -> String {
        switch value {
        case -70: return "\(Int(value)) dBFS（ごく小さな音も拾う）"
        case -30: return "\(Int(value)) dBFS（はっきりした音のみ）"
        default: return "\(Int(value)) dBFS"
        }
    }
}
