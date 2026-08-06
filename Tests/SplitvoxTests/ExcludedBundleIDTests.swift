import Foundation
import Testing
@testable import Splitvox

@Suite("除外バンドルID")
struct ExcludedBundleIDTests {

    private func makeStore(_ suite: String = #function) -> PreferenceStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return PreferenceStore(defaults: defaults)
    }

    @Test("既定では何も除外しない")
    func nothingExcludedByDefault() {
        #expect(makeStore().excludedBundleIDs.isEmpty)
    }

    @Test("除外したIDは保存されて読み戻せる")
    func excludedIDsRoundTrip() {
        let store = makeStore()

        store.excludedBundleIDs = ["notion.id", "com.apple.Music"]

        #expect(store.excludedBundleIDs == ["notion.id", "com.apple.Music"])
    }

    @Test("空行は捨てられる")
    func blankEntriesAreDiscarded() {
        let store = makeStore()

        store.excludedBundleIDs = ["notion.id", "  ", "", "com.apple.Music"]

        #expect(store.excludedBundleIDs == ["notion.id", "com.apple.Music"])
    }

    /// 除外は前方一致で判定する。通知音を出すのは本体ではなくヘルパー
    /// (notion.id.helper) であることが多く、いちいち列挙させたくないため。
    @Test("除外は前方一致でヘルパーにも及ぶ")
    func exclusionMatchesHelperProcesses() {
        let excluded = ["notion.id"]

        #expect(MeetingDetector.isExcluded("notion.id", by: excluded))
        #expect(MeetingDetector.isExcluded("notion.id.helper", by: excluded))
        #expect(MeetingDetector.isExcluded("com.google.Chrome", by: excluded) == false)
    }

    /// 前方一致が別アプリを巻き込まないこと。境界はドットで区切る。
    @Test("似た名前の別アプリを巻き込まない")
    func exclusionDoesNotMatchUnrelatedApps() {
        #expect(MeetingDetector.isExcluded("notion.identity.other", by: ["notion.id"]) == false)
        #expect(MeetingDetector.isExcluded("us.zoom.xoster", by: ["us.zoom.xos"]) == false)
    }

    @Test("除外したアプリは再生中でも条件を満たさない")
    func excludedAppDoesNotSatisfyPlayback() {
        let onlyExcluded = MeetingDetector.Sample(
            headsetActive: true,
            physicalHeadsetActive: true,
            microphoneInUse: true,
            playing: []
        )

        #expect(onlyExcluded.shouldRecord(matching: [.playback, .externalInput]) == false)
    }
}
