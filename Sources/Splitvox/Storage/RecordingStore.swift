import Foundation

enum RecordingStoreError: LocalizedError {
    case couldNotCreateDirectory(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateDirectory(let url, let underlying):
            return "録音の保存先を作成できませんでした: \(url.path) (\(underlying.localizedDescription))"
        }
    }
}

/// Owns where a recording session's files live.
///
/// The base directory is injected so tests can point at a temporary location;
/// production uses Application Support. Same shape as `PendingQueue` in
/// nani-mini.
struct RecordingStore {

    let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    static func defaultBaseDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Config.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(Config.recordingsDirectoryName, isDirectory: true)
    }

    /// Create a directory for one recording session.
    ///
    /// Named `yyyyMMdd-HHmmss` rather than ISO 8601: ISO 8601 contains colons,
    /// and the Finder renders a colon in a file name as a slash, which makes
    /// the paths confusing to read and to type.
    ///
    /// Created 0o700 because meeting audio is written here unencrypted.
    func createSessionDirectory(startedAt: Date) throws -> URL {
        let name = Self.directoryNameFormatter.string(from: startedAt)
        var candidate = baseDirectory.appendingPathComponent(name, isDirectory: true)

        // Stopping and restarting within the same second must not reuse a
        // directory and overwrite the previous recording.
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = baseDirectory.appendingPathComponent("\(name)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        do {
            try FileManager.default.createDirectory(
                at: candidate,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw RecordingStoreError.couldNotCreateDirectory(candidate, underlying: error)
        }

        return candidate
    }

    /// Setting only `locale` is not enough on a Mac configured for the Japanese
    /// calendar: `DateFormatter` keeps the system calendar, and `yyyy` then
    /// renders the Reiwa year (2026 becomes 0008). The calendar and time zone
    /// are pinned explicitly so directory names are always Gregorian and local.
    private static let directoryNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// 16-bit PCM WAV. Uncompressed float costs about
    /// 2 GB an hour across both tracks; 16-bit halves it losslessly for speech.
    static func microphoneFileURL(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("me.wav")
    }

    static func systemAudioFileURL(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("them.wav")
    }

    static func transcriptFileURL(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("transcript.md")
    }
}
