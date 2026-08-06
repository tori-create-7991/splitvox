import Testing
@testable import Splitvox

@Suite("AutoRecordConditions")
struct AutoRecordConditionTests {

    private func sample(
        headset: Bool = false,
        physical: Bool = false,
        micInUse: Bool = false,
        playing: [String] = []
    ) -> MeetingDetector.Sample {
        MeetingDetector.Sample(
            headsetActive: headset,
            physicalHeadsetActive: physical,
            microphoneInUse: micInUse,
            playing: playing
        )
    }

    private let audio = ["us.zoom.xos"]

    /// A set that matches everything would record all day, so an empty set is
    /// treated as "off" rather than "no constraints".
    @Test("条件を1つも有効にしなければ開始しない")
    func emptySetNeverStarts() {
        let everything = sample(headset: true, physical: true, micInUse: true, playing: audio)

        #expect(everything.shouldRecord(matching: []) == false)
    }

    @Test("有効にした条件はすべて満たす必要がある")
    func allEnabledConditionsMustHold() {
        let headsetOnly = sample(headset: true, playing: audio)

        #expect(headsetOnly.shouldRecord(matching: [.playback, .externalInput]))
        // マイクは使われていないので、追加すると成立しなくなる。
        #expect(headsetOnly.shouldRecord(matching: [.playback, .externalInput, .microphoneInUse]) == false)
    }

    @Test("実機の条件は仮想デバイスを除外する")
    func physicalConditionExcludesVirtualDevices() {
        let virtualDevice = sample(headset: true, physical: false, playing: audio)

        #expect(virtualDevice.shouldRecord(matching: [.playback, .externalInput]))
        #expect(virtualDevice.shouldRecord(matching: [.playback, .physicalInput]) == false)
    }

    /// The combination Notion uses: microphone activity, nothing about headsets.
    @Test("マイク使用の条件は動画視聴では成立しない")
    func microphoneConditionIgnoresPlaybackOnly() {
        let watching = sample(headset: true, physical: true, playing: audio)
        let calling = sample(headset: true, physical: true, micInUse: true, playing: audio)

        #expect(watching.shouldRecord(matching: [.playback, .microphoneInUse]) == false)
        #expect(calling.shouldRecord(matching: [.playback, .microphoneInUse]))
    }

    @Test("再生の条件を外すと無音でも開始する")
    func droppingPlaybackAllowsSilence() {
        let silentHeadset = sample(headset: true, playing: [])

        #expect(silentHeadset.shouldRecord(matching: [.playback, .externalInput]) == false)
        #expect(silentHeadset.shouldRecord(matching: [.externalInput]))
    }

    @Test("既定はヘッドセットと再生の組み合わせ")
    func defaultIsHeadsetPlusPlayback() {
        #expect(AutoRecordConditions.default == [.playback, .externalInput])
    }

    @Test("設定値は数値として往復できる")
    func rawValueRoundTrips() {
        let stored = AutoRecordConditions([.playback, .microphoneInUse])

        #expect(AutoRecordConditions(rawValue: stored.rawValue) == stored)
    }

    /// 削除した MeetingDetectorTests が固定していた判断。ヘッドセット無しで
    /// 音が鳴っていても開始しない。新しいテストは全て headset: true だったため
    /// この分岐は一度も検証されていなかった。
    @Test("ヘッドセットが無ければ音が鳴っていても開始しない")
    func audioWithoutHeadsetDoesNotStart() {
        let speakers = sample(headset: false, playing: audio)

        #expect(speakers.shouldRecord(matching: .default) == false)
    }

    /// これも削除で失われた意図。ヘッドセット経由の動画は「除外する対象」では
    /// なく、記録してよいという製品判断。
    @Test("ヘッドセット経由の動画は記録する")
    func videoThroughHeadsetIsRecorded() {
        let watching = sample(headset: true, playing: ["com.google.Chrome.helper"])

        #expect(watching.shouldRecord(matching: .default))
    }

    /// 16通りすべてを1つの表で押さえる。個別ケースを足し続けるより、
    /// 「有効な条件がすべて成立していること」という不変条件を直接検証する。
    @Test("有効な条件の全組み合わせで AND 判定になる")
    func everySubsetBehavesAsConjunction() {
        let signals: [(AutoRecordConditions, Bool)] = [
            (.playback, true),
            (.externalInput, true),
            (.physicalInput, false),
            (.microphoneInUse, true)
        ]
        // 実機を伴わないヘッドセット（仮想デバイス）で、マイクは使用中。
        let current = sample(headset: true, physical: false, micInUse: true, playing: audio)

        for raw in 0..<16 {
            let subset = AutoRecordConditions(rawValue: raw)
            let expected = !subset.isEmpty && signals.allSatisfy { option, holds in
                !subset.contains(option) || holds
            }

            #expect(
                current.shouldRecord(matching: subset) == expected,
                "subset rawValue \(raw) の判定が AND と一致しない"
            )
        }
    }

    @Test("すべての条件を有効にすると最も厳しくなる")
    func allConditionsIsStrictest() {
        let everything = AutoRecordConditions(AutoRecordConditions.orderedOptions)
        let full = sample(headset: true, physical: true, micInUse: true, playing: audio)
        let missingPhysical = sample(headset: true, physical: false, micInUse: true, playing: audio)

        #expect(full.shouldRecord(matching: everything))
        #expect(missingPhysical.shouldRecord(matching: everything) == false)
    }
}
