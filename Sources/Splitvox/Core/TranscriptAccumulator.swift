import Foundation

/// Collects finalised segments from both sides while a recording is running and
/// renders the transcript so far.
///
/// The two sides are transcribed independently, so segments do not arrive in
/// time order; rendering sorts them every time rather than assuming arrival
/// order means anything.
struct TranscriptAccumulator {

    private(set) var me: [TranscriptSegment] = []
    private(set) var them: [TranscriptSegment] = []

    /// Identity of everything already accepted, so a re-emitted range does not
    /// appear twice in the file the user is watching.
    private var seen: Set<String> = []

    /// Returns whether the transcript changed, so the caller can skip rewriting
    /// the file when nothing new arrived.
    @discardableResult
    mutating func add(_ segment: TranscriptSegment, from speaker: Speaker) -> Bool {
        let key = "\(speaker.label)|\(segment.start)|\(segment.end)|\(segment.text)"
        guard seen.insert(key).inserted else { return false }

        switch speaker {
        case .me: me.append(segment)
        case .them: them.append(segment)
        }
        return true
    }

    func markdown() -> String {
        TranscriptMerger.markdown(
            for: TranscriptMerger.mergeCoalescing(me: me, them: them)
        )
    }

    var isEmpty: Bool { me.isEmpty && them.isEmpty }
}
