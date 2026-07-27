import Testing
@testable import Splitvox

/// SpeechAnalyzer's time-indexed preset finalises in very small units — a real
/// 20s recording produced segments as short as "バ" and "ト". Rendered one per
/// line that is unreadable, so adjacent segments from the same speaker are
/// rejoined before rendering.
@Suite("TranscriptMerger.coalesce")
struct TranscriptCoalesceTests {

    private func labeled(
        _ speaker: Speaker,
        _ start: Double,
        _ end: Double,
        _ text: String
    ) -> LabeledSegment {
        LabeledSegment(speaker: speaker, segment: TranscriptSegment(start: start, end: end, text: text))
    }

    @Test("Fragments of one utterance are rejoined without inserting spaces")
    func fragmentsOfOneUtteranceAreRejoined() {
        // Shape taken from the real recording: one phrase split mid-word.
        let input = [
            labeled(.them, 6.0, 7.8, "はい、皆さん What'sア"),
            labeled(.them, 8.0, 8.4, "バ"),
            labeled(.them, 8.6, 14.0, "ッパー翔太でございます。")
        ]

        let result = TranscriptMerger.coalesce(input, maxGap: 1.0)

        #expect(result.count == 1)
        #expect(result[0].segment.text == "はい、皆さん What'sアバッパー翔太でございます。")
        #expect(result[0].segment.start == 6.0)
        #expect(result[0].segment.end == 14.0)
    }

    @Test("A pause longer than the gap keeps the segments separate")
    func longPauseKeepsSegmentsSeparate() {
        let input = [
            labeled(.them, 0, 2, "前半です"),
            labeled(.them, 5, 7, "後半です")
        ]

        let result = TranscriptMerger.coalesce(input, maxGap: 1.0)

        #expect(result.count == 2)
    }

    @Test("Segments from different speakers are never joined, however close")
    func differentSpeakersAreNeverJoined() {
        let input = [
            labeled(.them, 0, 2, "どうですか"),
            labeled(.me, 2.05, 3, "はい")
        ]

        let result = TranscriptMerger.coalesce(input, maxGap: 1.0)

        #expect(result.count == 2)
        #expect(result.map(\.speaker) == [.them, .me])
    }

    @Test("Overlapping segments from the same speaker still join")
    func overlappingSameSpeakerSegmentsJoin() {
        // A negative gap: the recogniser finalised ranges that overlap.
        let input = [
            labeled(.them, 0, 3, "前半"),
            labeled(.them, 2.5, 5, "後半")
        ]

        let result = TranscriptMerger.coalesce(input, maxGap: 1.0)

        #expect(result.count == 1)
        #expect(result[0].segment.text == "前半後半")
        #expect(result[0].segment.end == 5)
    }

    @Test("Joining keeps the widest end time even when a fragment ends early")
    func joiningKeepsWidestEndTime() {
        let input = [
            labeled(.them, 0, 9, "長い方"),
            labeled(.them, 9.1, 9.5, "短い方")
        ]

        let result = TranscriptMerger.coalesce(input, maxGap: 1.0)

        #expect(result[0].segment.end == 9.5)
    }

    @Test("Empty and single-element inputs pass through unchanged")
    func emptyAndSingleInputsPassThrough() {
        #expect(TranscriptMerger.coalesce([], maxGap: 1.0).isEmpty)

        let single = [labeled(.me, 0, 1, "ひとつ")]
        #expect(TranscriptMerger.coalesce(single, maxGap: 1.0) == single)
    }
}
