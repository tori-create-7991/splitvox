import Foundation
import Testing
@testable import Splitvox

@Suite("RecordingStore")
struct RecordingStoreTests {

    /// Real filesystem rather than a mock: the properties under test here are
    /// the directory name and its permission bits, which a mock would not have.
    private struct Fixture {
        let base: URL
        let store: RecordingStore

        init() {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("SplitvoxTests-\(UUID().uuidString)", isDirectory: true)
            store = RecordingStore(baseDirectory: base)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    /// The calendar is pinned for the same reason the production formatter pins
    /// it: this machine is configured for the Japanese calendar, so a formatter
    /// that only sets `locale` parses "2026" as Reiwa 2026 (year 4044).
    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        return formatter.date(from: value)!
    }

    @Test("A session directory is named for its start time without characters that break paths")
    func sessionDirectoryIsNamedForStartTime() throws {
        let fixture = Fixture()
        defer { fixture.remove() }

        let directory = try fixture.store.createSessionDirectory(startedAt: date("2026-07-26 14:05:09"))

        #expect(directory.lastPathComponent == "20260726-140509")
        #expect(directory.lastPathComponent.contains(":") == false)
        #expect(directory.lastPathComponent.contains("/") == false)
    }

    @Test("A session directory is created and readable only by its owner")
    func sessionDirectoryIsOwnerOnly() throws {
        let fixture = Fixture()
        defer { fixture.remove() }

        let directory = try fixture.store.createSessionDirectory(startedAt: date("2026-07-26 14:05:09"))

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o700)
    }

    @Test("Audio and transcript paths sit inside the session directory")
    func filePathsSitInsideSessionDirectory() throws {
        let fixture = Fixture()
        defer { fixture.remove() }

        let directory = try fixture.store.createSessionDirectory(startedAt: date("2026-07-26 14:05:09"))

        #expect(RecordingStore.microphoneFileURL(in: directory).lastPathComponent == "me.wav")
        #expect(RecordingStore.systemAudioFileURL(in: directory).lastPathComponent == "them.wav")
        #expect(RecordingStore.transcriptFileURL(in: directory).lastPathComponent == "transcript.md")
        #expect(RecordingStore.microphoneFileURL(in: directory)
            .deletingLastPathComponent() == directory)
    }

    @Test("Two sessions in the same second do not collide")
    func sessionsInTheSameSecondDoNotCollide() throws {
        let fixture = Fixture()
        defer { fixture.remove() }

        let startedAt = date("2026-07-26 14:05:09")
        let first = try fixture.store.createSessionDirectory(startedAt: startedAt)
        let second = try fixture.store.createSessionDirectory(startedAt: startedAt)

        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
}
