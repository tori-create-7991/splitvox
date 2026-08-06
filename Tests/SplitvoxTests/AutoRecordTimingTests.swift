import Testing
@testable import Splitvox

@Suite("AutoRecordTiming")
struct AutoRecordTimingTests {

    @Test("停止までの時間は開始までより長い")
    func stopDelayExceedsStartDelay() {
        let timing = AutoRecordTiming.default

        // 逆だと、人が黙るたびに会議が分割される。
        #expect(timing.stopAfter > timing.startAfter)
    }

    @Test("秒数は読みやすい単位に変換される")
    func secondsAreDescribedInReadableUnits() {
        #expect(AutoRecordTiming.describeSeconds(0) == "すぐに")
        #expect(AutoRecordTiming.describeSeconds(30) == "30 秒")
        #expect(AutoRecordTiming.describeSeconds(120) == "2 分")
        #expect(AutoRecordTiming.describeSeconds(7200) == "2 時間")
    }

    @Test("しきい値の両端には意味の説明が付く")
    func thresholdExtremesAreExplained() {
        #expect(AutoRecordTiming.describeThreshold(-70).contains("ごく小さな音"))
        #expect(AutoRecordTiming.describeThreshold(-30).contains("はっきりした音"))
        #expect(AutoRecordTiming.describeThreshold(-50) == "-50 dBFS")
    }

    @Test("既定値は選択肢に含まれている")
    func defaultsAreSelectable() {
        let timing = AutoRecordTiming.default

        #expect(AutoRecordTiming.startChoices.contains(timing.startAfter))
        #expect(AutoRecordTiming.stopChoices.contains(timing.stopAfter))
        #expect(AutoRecordTiming.maximumChoices.contains(timing.maximumDuration))
        #expect(AutoRecordTiming.thresholdChoices.contains(timing.playbackThresholdDecibels))
    }
}

@Suite("MeetingTrigger — 最大録音時間")
struct MeetingTriggerMaximumTests {

    /// An application left playing would otherwise record until the disk fills.
    @Test("条件が続いていても最大時間を超えたら停止する")
    func stopsAtMaximumDuration() {
        var trigger = MeetingTrigger(startAfter: 5, stopAfter: 30, maximumDuration: 100)
        _ = trigger.observe(meetingDetected: true, at: 0)
        _ = trigger.observe(meetingDetected: true, at: 5)

        #expect(trigger.observe(meetingDetected: true, at: 99) == .none)
        #expect(trigger.observe(meetingDetected: true, at: 105) == .stop)
    }

    @Test("最大時間で停止した後も次の録音を開始できる")
    func canRestartAfterMaximumDuration() {
        var trigger = MeetingTrigger(startAfter: 5, stopAfter: 30, maximumDuration: 100)
        _ = trigger.observe(meetingDetected: true, at: 0)
        _ = trigger.observe(meetingDetected: true, at: 5)
        _ = trigger.observe(meetingDetected: true, at: 105)

        _ = trigger.observe(meetingDetected: true, at: 106)
        #expect(trigger.observe(meetingDetected: true, at: 111) == .start)
    }
}
