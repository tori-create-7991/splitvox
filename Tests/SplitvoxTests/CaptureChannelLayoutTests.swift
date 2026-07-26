import Testing
@testable import Splitvox

@Suite("CaptureChannelLayout")
struct CaptureChannelLayoutTests {

    @Test("The measured layout on this machine puts the mono microphone before the stereo tap")
    func measuredLayoutIsMonoMicrophoneThenStereoTap() {
        // Measured with `Splitvox --probe-aggregate`: per stream [1, 2].
        let layout = CaptureChannelLayout.resolve(streamChannelCounts: [1, 2])

        #expect(layout?.microphoneChannels == 0..<1)
        #expect(layout?.systemAudioChannels == 1..<3)
        #expect(layout?.totalChannels == 3)
    }

    @Test("A stereo microphone shifts the tap channels rather than overlapping them")
    func stereoMicrophoneShiftsTapChannels() {
        let layout = CaptureChannelLayout.resolve(streamChannelCounts: [2, 2])

        #expect(layout?.microphoneChannels == 0..<2)
        #expect(layout?.systemAudioChannels == 2..<4)
        #expect(layout?.totalChannels == 4)
    }

    @Test("A missing tap stream yields no layout instead of recording silence into them.wav")
    func missingTapStreamYieldsNoLayout() {
        #expect(CaptureChannelLayout.resolve(streamChannelCounts: [1]) == nil)
        #expect(CaptureChannelLayout.resolve(streamChannelCounts: []) == nil)
    }

    @Test("An unexpected stream count yields no layout rather than guessing")
    func unexpectedStreamCountYieldsNoLayout() {
        #expect(CaptureChannelLayout.resolve(streamChannelCounts: [1, 2, 2]) == nil)
    }

    @Test("A stream with no channels yields no layout")
    func emptyStreamYieldsNoLayout() {
        #expect(CaptureChannelLayout.resolve(streamChannelCounts: [0, 2]) == nil)
        #expect(CaptureChannelLayout.resolve(streamChannelCounts: [1, 0]) == nil)
    }
}
