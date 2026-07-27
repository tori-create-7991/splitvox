import Testing
@testable import Splitvox

/// SpeechAnalyzer's time-indexed preset finalises in very small units — a real
/// 20s recording produced segments as short as "マ" and "大", split mid-word.
/// Rendered one per line that is unreadable, so each side's fragments are
/// rejoined before the two sides are interleaved.
@Suite("TranscriptMerger.coalesce")
struct TranscriptCoalesceTests {

    private func segment(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    @Test("Fragments of one utterance are rejoined without inserting spaces")
    func fragmentsOfOneUtteranceAreRejoined() {
        // Shape taken from the real recording: one phrase split mid-word.
        let input = [
            segment(6.0, 7.8, "はい、皆さん What'sア"),
            segment(8.0, 8.4, "バ"),
            segment(8.6, 14.0, "ッパー翔太でございます。")
        ]

        let result = TranscriptMerger.coalesce(input, maxGap: 1.0)

        #expect(result.count == 1)
        #expect(result[0].text == "はい、皆さん What'sアバッパー翔太でございます。")
        #expect(result[0].start == 6.0)
        #expect(result[0].end == 14.0)
    }

    @Test("A pause longer than the gap keeps the segments separate")
    func longPauseKeepsSegmentsSeparate() {
        let input = [segment(0, 2, "前半です"), segment(5, 7, "後半です")]

        #expect(TranscriptMerger.coalesce(input, maxGap: 1.0).count == 2)
    }

    @Test("Overlapping fragments still join")
    func overlappingFragmentsJoin() {
        // A negative gap: the recogniser finalised ranges that overlap.
        let input = [segment(0, 3, "前半"), segment(2.5, 5, "後半")]

        let result = TranscriptMerger.coalesce(input, maxGap: 1.0)

        #expect(result.count == 1)
        #expect(result[0].text == "前半後半")
        #expect(result[0].end == 5)
    }

    @Test("Joining keeps the widest end time even when a fragment ends early")
    func joiningKeepsWidestEndTime() {
        let input = [segment(0, 9, "長い方"), segment(9.1, 9.5, "短い方")]

        #expect(TranscriptMerger.coalesce(input, maxGap: 1.0)[0].end == 9.5)
    }

    @Test("Empty and single-element inputs pass through unchanged")
    func emptyAndSingleInputsPassThrough() {
        #expect(TranscriptMerger.coalesce([], maxGap: 1.0).isEmpty)

        let single = [segment(0, 1, "ひとつ")]
        #expect(TranscriptMerger.coalesce(single, maxGap: 1.0) == single)
    }

    /// Regression for the ordering bug found on real output: coalescing after
    /// merging silently does nothing while both people are talking, because the
    /// merged timeline never puts two same-speaker entries next to each other.
    @Test("Coalescing each side before merging rejoins fragments that survive an interleaved timeline")
    func coalescingBeforeMergingSurvivesInterleaving() {
        // Verbatim shape from the failing run: each speaker's sentence was cut
        // in two, and the two speakers alternate in time.
        let me = [segment(10.0, 10.4, "マ"), segment(13.0, 15.0, "イクテストをしています")]
        let them = [segment(10.1, 10.3, "大"), segment(10.5, 14.0, "変興味深い国なんで")]

        let result = TranscriptMerger.mergeCoalescing(me: me, them: them, maxGap: 3.0)

        #expect(result.count == 2)
        #expect(result.first { $0.speaker == .me }?.segment.text == "マイクテストをしています")
        #expect(result.first { $0.speaker == .them }?.segment.text == "大変興味深い国なんで")
    }

    @Test("Merging still separates the two sides after coalescing")
    func mergingStillSeparatesSidesAfterCoalescing() {
        let me = [segment(0, 1, "こちら")]
        let them = [segment(2, 3, "あちら")]

        let result = TranscriptMerger.mergeCoalescing(me: me, them: them)

        #expect(result.map(\.speaker) == [.me, .them])
        #expect(result.map(\.segment.text) == ["こちら", "あちら"])
    }
}
