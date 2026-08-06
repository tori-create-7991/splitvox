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
}
