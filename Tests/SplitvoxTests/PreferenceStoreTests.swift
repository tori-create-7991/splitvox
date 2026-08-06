import Foundation
import Testing
@testable import Splitvox

@Suite("PreferenceStore")
struct PreferenceStoreTests {

    /// Each test gets its own suite so stored values cannot leak between them
    /// or into the real user defaults. Qualified by type as well: two suites
    /// deriving a domain from `#function` alone
    /// collided on identically-named tests and wiped each other's domain when
    /// run in parallel.
    private func makeStore(_ test: String = #function) -> (PreferenceStore, UserDefaults) {
        let suite = "\(Self.self).\(test)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PreferenceStore(defaults: defaults), defaults)
    }

    @Test("An unconfigured store reports the built-in meeting applications")
    func unconfiguredStoreReportsDefaults() {
        let (store, _) = makeStore()

        #expect(store.meetingBundleIDs == Config.defaultMeetingBundleIDs)
        #expect(store.inputDeviceUID == nil)
    }

    @Test("Stored bundle IDs are read back")
    func storedBundleIDsAreReadBack() {
        let (store, _) = makeStore()

        store.meetingBundleIDs = ["us.zoom.xos", "us.zoom.caphost"]

        #expect(store.meetingBundleIDs == ["us.zoom.xos", "us.zoom.caphost"])
    }

    /// An empty list would tap nothing and record silence into them.wav, which
    /// looks identical to a broken recording. Falling back keeps the app usable.
    @Test("Clearing the bundle ID list falls back to the defaults instead of capturing nothing")
    func clearingBundleIDsFallsBackToDefaults() {
        let (store, _) = makeStore()

        store.meetingBundleIDs = []

        #expect(store.meetingBundleIDs == Config.defaultMeetingBundleIDs)
    }

    @Test("Blank entries are discarded so a stray newline cannot break the tap")
    func blankEntriesAreDiscarded() {
        let (store, _) = makeStore()

        store.meetingBundleIDs = ["com.google.Chrome", "   ", "", "com.google.Chrome.helper"]

        #expect(store.meetingBundleIDs == ["com.google.Chrome", "com.google.Chrome.helper"])
    }

    @Test("Selecting an input device is remembered, and clearing it returns to the system default")
    func inputDeviceSelectionRoundTrips() {
        let (store, _) = makeStore()

        store.inputDeviceUID = "BuiltInMicrophoneDevice"
        #expect(store.inputDeviceUID == "BuiltInMicrophoneDevice")

        store.inputDeviceUID = nil
        #expect(store.inputDeviceUID == nil)
    }

    /// 空集合は「未設定」ではなく「明示的に無効」。素朴な integer(forKey:) に
    /// 単純化すると、条件を全部外した利用者に対して自動記録が復活する。
    @Test("条件を空にした状態と未設定は区別される")
    func emptyConditionSetIsDistinctFromUnset() {
        let (store, _) = makeStore()

        #expect(store.autoRecordConditions == .default)

        store.autoRecordConditions = []
        #expect(store.autoRecordConditions.isEmpty)
    }

    /// 素朴な bool(forKey:) は未設定で false を返す。この既定が反転すると、
    /// 相手側が無音だったことに気づく唯一の手段が消える。
    @Test("無音警告は未設定なら有効")
    func silentWarningDefaultsToEnabled() {
        let (store, _) = makeStore()

        #expect(store.warnOnSilentFarSide)

        store.warnOnSilentFarSide = false
        #expect(store.warnOnSilentFarSide == false)
    }

    @Test("時間設定は往復できる")
    func timingRoundTrips() {
        let (store, _) = makeStore()

        store.autoRecordTiming = AutoRecordTiming(
            startAfter: 10, stopAfter: 60, maximumDuration: 3600
        )

        let loaded = store.autoRecordTiming
        #expect(loaded.startAfter == 10)
        #expect(loaded.stopAfter == 60)
        #expect(loaded.maximumDuration == 3600)
    }

    /// 0 が入ると上限が毎回即座に成立し、3秒ごとのセッションが量産される。
    @Test("範囲外の時間設定は既定に落ちる")
    func outOfRangeTimingFallsBackToDefault() {
        let (store, defaults) = makeStore()

        defaults.set(0.0, forKey: "autoRecordMaximumDuration")
        defaults.set(-5.0, forKey: "autoRecordStartAfter")

        let loaded = store.autoRecordTiming
        #expect(loaded.maximumDuration == AutoRecordTiming.default.maximumDuration)
        #expect(loaded.startAfter == AutoRecordTiming.default.startAfter)
    }

    /// 下限だけ守っても意味がない。上限を超えた値も同じ経路で入ってくる。
    @Test("上限を超えた時間設定も既定に落ちる")
    func aboveMaximumTimingFallsBackToDefault() {
        let (store, defaults) = makeStore()

        defaults.set(999_999_999.0, forKey: "autoRecordMaximumDuration")

        #expect(store.autoRecordTiming.maximumDuration == AutoRecordTiming.default.maximumDuration)
    }

    /// 範囲内でも選択肢に無い値は Picker のタグと一致せず、設定画面が空欄になる。
    @Test("選択肢に無い時間設定は既定に落ちる")
    func unofferedTimingFallsBackToDefault() {
        let (store, defaults) = makeStore()

        defaults.set(7.0, forKey: "autoRecordStartAfter")

        #expect(store.autoRecordTiming.startAfter == AutoRecordTiming.default.startAfter)
    }

    /// 新しい版が5つ目の条件を書き込んだ後にダウングレードした場合。
    @Test("未知のビットは読み込み時に落とされる")
    func unknownConditionBitsAreDropped() {
        let (store, defaults) = makeStore()

        defaults.set(AutoRecordConditions.default.rawValue | (1 << 4), forKey: "autoRecordCondition")

        #expect(store.autoRecordConditions == .default)
    }

    /// 提示していない言語が入ると Picker に一致するタグが無くなり空欄になる。
    @Test("提示外の言語は既定に落ちる")
    func unofferedLocaleFallsBackToDefault() {
        let (store, defaults) = makeStore()

        defaults.set("xx-YY", forKey: "transcriptionLocale")
        #expect(store.transcriptionLocaleIdentifier == Config.transcriptionLocaleIdentifier)

        store.transcriptionLocaleIdentifier = "en-US"
        #expect(store.transcriptionLocaleIdentifier == "en-US")
    }

    @Test("A snapshot stays stable while the stored values change underneath")
    func snapshotStaysStableWhileStoredValuesChange() {
        let (store, _) = makeStore()
        store.meetingBundleIDs = ["com.google.Chrome"]

        let snapshot = store.current
        store.meetingBundleIDs = ["us.zoom.xos"]

        #expect(snapshot.meetingBundleIDs == ["com.google.Chrome"])
    }
}
