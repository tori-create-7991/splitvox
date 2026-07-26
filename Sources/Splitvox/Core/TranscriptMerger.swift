import Foundation

/// Which side of the call produced a segment.
///
/// This is the whole point of the two-file capture: the speaker is known from
/// which file the audio came out of, not inferred from the audio itself.
enum Speaker: Equatable {
    /// The local microphone.
    case me
    /// Everyone on the far end, mixed together by the process tap.
    case them

    var label: String {
        switch self {
        case .me: return "自分"
        case .them: return "相手"
        }
    }

    /// Tie-break rank, so a shared start time still produces a stable order.
    fileprivate var rank: Int {
        switch self {
        case .me: return 0
        case .them: return 1
        }
    }
}

/// One recognised utterance, in seconds from the start of the recording.
///
/// Deliberately expressed as `TimeInterval` rather than `CMTimeRange` so this
/// type — and the merger built on it — carry no CoreMedia dependency and stay
/// trivially testable. `Transcriber` converts at the boundary.
struct TranscriptSegment: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// A segment together with the side that said it.
struct LabeledSegment: Equatable {
    let speaker: Speaker
    let segment: TranscriptSegment
}

enum TranscriptMerger {

    /// Interleave both sides into a single ascending timeline.
    ///
    /// Overlapping speech is preserved as two segments rather than resolved:
    /// people talking over each other is information about the meeting, and
    /// discarding either side would lose words.
    static func merge(me: [TranscriptSegment], them: [TranscriptSegment]) -> [LabeledSegment] {
        let labeled = me.map { LabeledSegment(speaker: .me, segment: $0) }
            + them.map { LabeledSegment(speaker: .them, segment: $0) }

        // Swift's sort is not stable, so every field used for ordering is
        // compared explicitly; otherwise equal start times could reorder
        // between runs and make the output non-reproducible.
        return labeled.sorted { lhs, rhs in
            if lhs.segment.start != rhs.segment.start {
                return lhs.segment.start < rhs.segment.start
            }
            if lhs.speaker != rhs.speaker {
                return lhs.speaker.rank < rhs.speaker.rank
            }
            return lhs.segment.end < rhs.segment.end
        }
    }

    /// Render as Markdown, one line per segment.
    static func markdown(for segments: [LabeledSegment]) -> String {
        segments
            .map { "- **[\($0.speaker.label)]** `\(timestamp($0.segment.start))` \($0.segment.text)" }
            .joined(separator: "\n")
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
