import Testing
@testable import Splitvox

@Suite("TranscriptMerger")
struct TranscriptMergerTests {

    private func segment(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    @Test("Segments from both sides interleave in ascending start order")
    func interleavesBothSidesByStartTime() {
        let me = [segment(2, 3, "はい"), segment(6, 7, "そうですね")]
        let them = [segment(0, 1, "こんにちは"), segment(4, 5, "本題ですが")]

        let merged = TranscriptMerger.merge(me: me, them: them)

        #expect(merged.map(\.segment.text) == ["こんにちは", "はい", "本題ですが", "そうですね"])
        #expect(merged.map(\.speaker) == [.them, .me, .them, .me])
    }

    @Test("A tie on start time orders the local speaker first, deterministically")
    func tieOnStartTimeIsDeterministic() {
        let me = [segment(1, 2, "self")]
        let them = [segment(1, 2, "remote")]

        let forward = TranscriptMerger.merge(me: me, them: them)
        let reversed = TranscriptMerger.merge(me: me, them: them)

        #expect(forward.map(\.speaker) == [.me, .them])
        #expect(forward == reversed)
    }

    @Test("Overlapping speech keeps both segments instead of dropping one")
    func overlappingSpeechKeepsBothSegments() {
        // Both people talk over each other between 1.5s and 3.0s.
        let me = [segment(1, 3, "ちょっといいですか")]
        let them = [segment(1.5, 4, "つまりこういうことで")]

        let merged = TranscriptMerger.merge(me: me, them: them)

        #expect(merged.count == 2)
        #expect(merged.map(\.speaker) == [.me, .them])
    }

    @Test("An empty side yields the other side unchanged")
    func emptySideYieldsOtherSideUnchanged() {
        let them = [segment(0, 1, "一人で喋っています"), segment(2, 3, "以上です")]

        let merged = TranscriptMerger.merge(me: [], them: them)

        #expect(merged.map(\.segment) == them)
        #expect(merged.allSatisfy { $0.speaker == .them })
    }

    @Test("Empty input yields an empty result")
    func emptyInputYieldsEmptyResult() {
        #expect(TranscriptMerger.merge(me: [], them: []).isEmpty)
    }

    @Test("Markdown renders one labelled line per segment with a timestamp")
    func markdownRendersLabelledLines() {
        let merged = TranscriptMerger.merge(
            me: [segment(7, 9, "よろしくお願いします")],
            them: [segment(4, 6, "今日はよろしくお願いします")]
        )

        let markdown = TranscriptMerger.markdown(for: merged)

        #expect(markdown == """
        - **[相手]** `00:00:04` 今日はよろしくお願いします
        - **[自分]** `00:00:07` よろしくお願いします
        """)
    }

    @Test("Timestamps past an hour keep hour, minute and second fields")
    func timestampsPastAnHourRenderAllFields() {
        let merged = TranscriptMerger.merge(me: [segment(3661, 3662, "長い会議")], them: [])

        #expect(TranscriptMerger.markdown(for: merged) == "- **[自分]** `01:01:01` 長い会議")
    }
}
