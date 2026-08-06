import Foundation
import Testing
@testable import Splitvox

@Suite("除外バンドルID")
struct ExcludedBundleIDTests {

    /// Suite names are qualified by type. Two suites deriving a `UserDefaults`
    /// domain from `#function` alone collided on identically-named tests and
    /// wiped each other's domain under parallel execution.
    private func makeStore(_ test: String = #function) -> PreferenceStore {
        let suite = "\(Self.self).\(test)"
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
    func blankExclusionEntriesAreDiscarded() {
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

    /// 利用者が大文字で打った除外指定が黙って効かない、が最も起きやすい失敗。
    @Test("大文字小文字を区別しない")
    func exclusionIsCaseInsensitive() {
        #expect(MeetingDetector.isExcluded("notion.id.helper", by: ["Notion.ID"]))
        #expect(MeetingDetector.isExcluded("com.Google.Chrome", by: ["com.google.chrome"]))
    }

    @Test("空の指定と空のリストは何にも一致しない")
    func emptyPatternsMatchNothing() {
        #expect(MeetingDetector.isExcluded("com.google.Chrome", by: [""]) == false)
        #expect(MeetingDetector.isExcluded("com.google.Chrome", by: []) == false)
    }

    /// 以前のテストは Sample を手で組み立てるだけで、除外フィルタ自体を一度も
    /// 通していなかった。フィルタの行を消してもテストは全て通る状態だった。
    @Test("再生中の一覧から除外アプリが取り除かれる")
    func filterRemovesExcludedFromPlaying() {
        let result = MeetingDetector.filterPlaying(
            producing: ["com.google.Chrome.helper", "notion.id.helper"],
            configured: ["com.google.Chrome.helper", "notion.id.helper"],
            excluded: ["notion.id"]
        )

        #expect(result == ["com.google.Chrome.helper"])
    }

    @Test("設定に含まれないアプリは再生中でも対象にならない")
    func filterKeepsOnlyConfiguredApps() {
        let result = MeetingDetector.filterPlaying(
            producing: ["com.google.Chrome.helper", "com.apple.Music"],
            configured: ["com.google.Chrome.helper"],
            excluded: []
        )

        #expect(result == ["com.google.Chrome.helper"])
    }

    @Test("対象アプリをすべて除外すると再生中は空になる")
    func excludingEveryConfiguredAppEmptiesPlaying() {
        let result = MeetingDetector.filterPlaying(
            producing: ["com.google.Chrome.helper"],
            configured: ["com.google.Chrome.helper"],
            excluded: ["com.google.Chrome"]
        )

        #expect(result.isEmpty)
    }

    @Test("設定に無いIDを除外しても影響しない")
    func excludingAnUnconfiguredAppIsANoOp() {
        let result = MeetingDetector.filterPlaying(
            producing: ["com.google.Chrome.helper"],
            configured: ["com.google.Chrome.helper"],
            excluded: ["com.apple.Music"]
        )

        #expect(result == ["com.google.Chrome.helper"])
    }

    /// マイク使用の条件だけを有効にした場合、除外が効かないと Siri や除外済み
    /// アプリが無人録音を開始してしまう。
    @Test("マイク使用の一覧からも除外アプリが取り除かれる")
    func filterRemovesExcludedFromCapturing() {
        let result = MeetingDetector.filterCapturing(
            ["notion.id.helper", "us.zoom.xos"],
            excluded: ["notion.id"]
        )

        #expect(result == ["us.zoom.xos"])
    }

    @Test("splitvox 自身はマイク使用として数えない")
    func selfIsNeverCountedAsCapturing() {
        let result = MeetingDetector.filterCapturing([Config.bundleIdentifier], excluded: [])

        // 自分を数えると .microphoneInUse が自己保持し、録音が止まらなくなる。
        #expect(result.isEmpty)
    }
}
