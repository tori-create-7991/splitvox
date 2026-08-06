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
    /// fills — roughly a gigabyte an hour. `MeetingTrigger` holds the trigger
    /// closed after the cap fires until the conditions lapse once, so a run
    /// that never pauses cannot continue past the cap. It bounds a continuous
    /// run, not a day's total: a single non-matching sample re-arms it.
    ///
    /// Measured against `systemUptime`, so it bounds awake time, not wall time.
    var maximumDuration: TimeInterval

    static let `default` = AutoRecordTiming(
        startAfter: 5,
        stopAfter: 30,
        maximumDuration: 4 * 60 * 60
    )

    static let startChoices: [TimeInterval] = [0, 3, 5, 10, 30]
    static let stopChoices: [TimeInterval] = [10, 30, 60, 120, 300]
    static let maximumChoices: [TimeInterval] = [30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60, 8 * 60 * 60]

    static func describeSeconds(_ value: TimeInterval) -> String {
        if value == 0 { return "すぐに" }
        if value < 60 { return "\(Int(value)) 秒" }
        if value < 3600 { return "\(Int(value / 60)) 分" }
        return "\(Int(value / 3600)) 時間"
    }

}
