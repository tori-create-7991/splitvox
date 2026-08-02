import Testing
@testable import Splitvox

@Suite("TranscriptAccumulator")
struct TranscriptAccumulatorTests {

    private func segment(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    @Test("A new accumulator renders nothing")
    func newAccumulatorRendersNothing() {
        #expect(TranscriptAccumulator().markdown().isEmpty)
    }

    @Test("Added segments appear in the rendered transcript under their speaker")
    func addedSegmentsAppearUnderTheirSpeaker() {
        var accumulator = TranscriptAccumulator()

        _ = accumulator.add(segment(0, 2, "そちらの声"), from: .them)
        _ = accumulator.add(segment(4, 6, "こちらの声"), from: .me)

        let markdown = accumulator.markdown()

        #expect(markdown.contains("**[相手]**"))
        #expect(markdown.contains("そちらの声"))
        #expect(markdown.contains("**[自分]**"))
        #expect(markdown.contains("こちらの声"))
    }

    /// The recogniser can re-emit a finalised range. Appending it twice would
    /// duplicate the text in the file that the user is watching.
    @Test("Re-adding an identical segment is ignored and reports no change")
    func reAddingIdenticalSegmentIsIgnored() {
        var accumulator = TranscriptAccumulator()
        let duplicate = segment(0, 2, "同じ発言")

        let first = accumulator.add(duplicate, from: .them)
        let second = accumulator.add(duplicate, from: .them)

        #expect(first)
        #expect(second == false)

        // Rendered once, not twice.
        let occurrences = accumulator.markdown().components(separatedBy: "同じ発言").count - 1
        #expect(occurrences == 1)
    }

    @Test("The same text from the other speaker is kept, not treated as a duplicate")
    func sameTextFromOtherSpeakerIsKept() {
        var accumulator = TranscriptAccumulator()
        let text = segment(0, 2, "はい")

        _ = accumulator.add(text, from: .me)
        let added = accumulator.add(text, from: .them)

        #expect(added)
        #expect(accumulator.markdown().components(separatedBy: "はい").count - 1 == 2)
    }

    /// Live results arrive as fragments split mid-word, exactly as in the batch
    /// path, so the accumulator has to coalesce before rendering.
    @Test("Fragments from one speaker are coalesced in the rendered output")
    func fragmentsAreCoalescedInOutput() {
        var accumulator = TranscriptAccumulator()

        _ = accumulator.add(segment(10.0, 10.4, "マ"), from: .me)
        _ = accumulator.add(segment(10.5, 12.0, "イクテスト"), from: .me)

        let markdown = accumulator.markdown()

        #expect(markdown.contains("マイクテスト"))
        #expect(markdown.components(separatedBy: "**[自分]**").count - 1 == 1)
    }

    @Test("Segments render in time order regardless of the order they arrived in")
    func segmentsRenderInTimeOrder() {
        var accumulator = TranscriptAccumulator()

        // The two sides are transcribed independently, so a later timestamp can
        // be finalised before an earlier one from the other side.
        _ = accumulator.add(segment(9, 10, "あとの発言"), from: .me)
        _ = accumulator.add(segment(1, 2, "さきの発言"), from: .them)

        let markdown = accumulator.markdown()
        let firstIndex = markdown.range(of: "さきの発言")!.lowerBound
        let secondIndex = markdown.range(of: "あとの発言")!.lowerBound

        #expect(firstIndex < secondIndex)
    }
}
