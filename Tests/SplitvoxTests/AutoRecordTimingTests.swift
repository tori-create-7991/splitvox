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


    @Test("既定値は選択肢に含まれている")
    func defaultsAreSelectable() {
        let timing = AutoRecordTiming.default

        #expect(AutoRecordTiming.startChoices.contains(timing.startAfter))
        #expect(AutoRecordTiming.stopChoices.contains(timing.stopAfter))
        #expect(AutoRecordTiming.maximumChoices.contains(timing.maximumDuration))
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

    /// 上限は「暴走防止」として実効でなければならない。停止直後に再開できると
    /// 4時間ごとのファイルが延々と積み上がり、ディスクは同じ速度で埋まる。
    @Test("上限で停止した後は条件が途切れるまで再開しない")
    func doesNotRestartUntilConditionsLapse() {
        var trigger = MeetingTrigger(startAfter: 5, stopAfter: 30, maximumDuration: 100)
        _ = trigger.observe(meetingDetected: true, at: 0)
        _ = trigger.observe(meetingDetected: true, at: 5)
        _ = trigger.observe(meetingDetected: true, at: 105)

        // 条件が続いている限り再開しない。
        #expect(trigger.observe(meetingDetected: true, at: 200) == .none)
        #expect(trigger.observe(meetingDetected: true, at: 10_000) == .none)
    }

    @Test("条件が一度途切れれば次の録音を開始できる")
    func restartsOnceConditionsLapse() {
        var trigger = MeetingTrigger(startAfter: 5, stopAfter: 30, maximumDuration: 100)
        _ = trigger.observe(meetingDetected: true, at: 0)
        _ = trigger.observe(meetingDetected: true, at: 5)
        _ = trigger.observe(meetingDetected: true, at: 105)

        _ = trigger.observe(meetingDetected: false, at: 110)
        _ = trigger.observe(meetingDetected: true, at: 120)

        #expect(trigger.observe(meetingDetected: true, at: 125) == .start)
    }

    /// 上限と停止条件が同時に成立しても .stop は1回だけ。
    @Test("上限と停止条件が重なっても停止は1度だけ")
    func capAndLapseDoNotStopTwice() {
        var trigger = MeetingTrigger(startAfter: 5, stopAfter: 30, maximumDuration: 100)
        _ = trigger.observe(meetingDetected: true, at: 0)
        _ = trigger.observe(meetingDetected: true, at: 5)

        #expect(trigger.observe(meetingDetected: false, at: 105) == .stop)
        #expect(trigger.observe(meetingDetected: false, at: 200) == .none)
    }

    /// 設定ウィンドウを閉じるたびにトリガーを作り直すと、録音中の状態が消えて
    /// 上限の計時がリセットされ、停止も二度と発火しなくなっていた。
    @Test("時間設定を差し替えても録音中の状態は保たれる")
    func adoptingTimingPreservesRunState() {
        var trigger = MeetingTrigger(startAfter: 5, stopAfter: 30, maximumDuration: 100)
        _ = trigger.observe(meetingDetected: true, at: 0)
        _ = trigger.observe(meetingDetected: true, at: 5)

        var updated = trigger.adopting(
            timing: AutoRecordTiming(startAfter: 5, stopAfter: 30, maximumDuration: 100)
        )

        #expect(updated.isCurrentlyRecording)
        // 計時が引き継がれているので、作り直しても上限は元の開始時刻から測る。
        #expect(updated.observe(meetingDetected: true, at: 105) == .stop)
    }

    @Test("差し替え後は新しい閾値が使われる")
    func adoptingTimingAppliesNewThresholds() {
        var trigger = MeetingTrigger(startAfter: 5, stopAfter: 30, maximumDuration: 100)
        _ = trigger.observe(meetingDetected: true, at: 0)

        var updated = trigger.adopting(
            timing: AutoRecordTiming(startAfter: 30, stopAfter: 30, maximumDuration: 100)
        )

        #expect(updated.observe(meetingDetected: true, at: 10) == .none)
        #expect(updated.observe(meetingDetected: true, at: 30) == .start)
    }
}
