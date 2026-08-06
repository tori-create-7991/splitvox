import Foundation

/// Append-only log written beside each recording.
///
/// Exists because a failed recording is otherwise unexplainable after the fact.
/// A real meeting produced a 265 MB `them.wav` containing pure silence, and
/// nothing on disk said which applications were configured, which were actually
/// playing, or whether the two ever overlapped. Guessing at bundle IDs after
/// the meeting is over is not a debugging strategy.
///
/// Written to the session directory rather than the system log so it travels
/// with the recording it describes.
final class SessionLog {

    private let url: URL
    private let queue = DispatchQueue(label: "com.ryo.splitvox.sessionlog")
    private let started = Date()

    init(directory: URL) {
        self.url = directory.appendingPathComponent("session.log")
    }

    func write(_ message: String) {
        let elapsed = Date().timeIntervalSince(started)
        let line = String(format: "[%7.1fs] %@\n", elapsed, message)

        queue.async { [url] in
            guard let data = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Record which applications are configured versus which are actually
    /// producing sound.
    ///
    /// The gap between those two lists is the single most common cause of a
    /// silent recording, and it is invisible unless captured while it happens.
    /// Excluded applications are omitted entirely. A user who excluded an app
    /// asked not to have it observed; honouring that in the trigger while
    /// writing it to disk every 15 seconds would be inconsistent.
    func logAudioSources(configured: [String], excluded: [String] = []) {
        let playing = Set(AudioProcessLookup.bundleIDsProducingOutput())
            .subtracting([Config.bundleIdentifier])
            .filter { !MeetingDetector.isExcluded($0, by: excluded) }

        let captured = playing.intersection(configured).sorted()
        let missed = playing.subtracting(configured).sorted()

        write("playing & captured: \(captured.isEmpty ? "(none)" : captured.joined(separator: ", "))")
        if !missed.isEmpty {
            write("playing but NOT captured: \(missed.joined(separator: ", "))  <-- 設定に追加が必要")
        }
    }

    func flush() {
        queue.sync { }
    }
}
