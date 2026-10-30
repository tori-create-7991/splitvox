import Foundation
import Testing
@testable import SplitvoxNotion

@Suite("Notion meeting notes")
struct NotionMeetingNotesTests {
    @Test("Matching uses calendar time and excludes distant notes")
    func matching() throws {
        let date = NotionNote.parseDate("2026-10-27T10:00:00Z")!
        let response: [String: Any] = ["results": [
            ["id": "first", "created_time": "2026-10-26T10:00:00Z", "meeting_notes": ["calendar_event": ["start_time": "2026-10-27T10:05:00Z"], "children": ["notes_block_id": "notes"]]],
            ["id": "unfinished", "created_time": "2026-10-20T10:00:00Z", "meeting_notes": [:]],
            ["id": "other", "created_time": "2026-10-27T15:00:00Z", "meeting_notes": ["children": ["notes_block_id": "othernotes"]]]
        ]]
        let notes = try NotionNote.candidates(response, startedAt: date, window: 600)
        #expect(notes.map(\.id) == ["first"])
    }

    @Test("Saturated queries fail closed instead of creating duplicates")
    func saturated() {
        #expect(throws: (any Error).self) {
            try NotionNote.candidates(["results": Array(repeating: ["id": "x"], count: 50)], startedAt: Date(), window: 600)
        }
    }

    @Test("Text chunks preserve Unicode and remain below API UTF16 limits")
    func chunks() {
        let input = String(repeating: "😃日本語\n", count: 1300)
        let chunks = NotionMeetingNotes.chunks(input)
        #expect(chunks.joined() == input)
        #expect(chunks.allSatisfy { $0.utf16.count <= 1800 })
    }

    @Test("New note markup contains only a fixed Notes section")
    func markup() {
        let text = NotionMeetingNotes.newNoteMarkdown()
        #expect(text.contains("<meeting-notes-section-notes>"))
        #expect(!text.contains("meeting-notes-section-transcript"))
    }

    @Test("Standalone CLI matching window defaults to ten minutes")
    func defaults() {
        #expect(NotionConfiguration().windowMinutes == 10)
    }
}

private final class FakeNotionAPI {
    let noteID = "11111111-1111-4111-8111-111111111111"
    let notesID = "22222222-2222-4222-8222-222222222222"
    let pageID = "33333333-3333-4333-8333-333333333333"
    var blocks: [String: [[String: Any]]] = [:]
    var page: [String: Any]?
    var mutations = 0
    var largestBatch = 0
    var rejectCreate = false
    var rejectBatch = false
    var failCreateAfterCommit = false
    var failCreateBeforeCommit = false
    var failChunkAfterCommit = false
    var failChunkBeforeCommit = false

    init() { blocks[notesID] = [["id": "original", "type": "paragraph", "paragraph": ["rich_text": [["plain_text": "Existing agenda"]]]]] }
    var note: [String: Any] { ["id": noteID, "type": "meeting_notes", "created_time": "2026-10-27T10:00:00Z", "meeting_notes": ["title": [["plain_text": "Meeting"]], "children": ["notes_block_id": notesID]]] }

    func call(_ method: String, _ endpoint: String, _ body: [String: Any]?) throws -> [String: Any] {
        if endpoint == "/v1/blocks/meeting_notes/query" { return ["results": []] }
        if endpoint == "/v1/search" { return ["results": page.map { [$0] } ?? [], "has_more": false] }
        if endpoint == "/v1/pages" {
            mutations += 1
            if rejectCreate { rejectCreate = false; throw NotionFailure("denied", definiteRejection: true) }
            if failCreateBeforeCommit { failCreateBeforeCommit = false; throw NotionFailure("timeout") }
            page = ["id": pageID, "properties": body!["properties"]!]
            blocks[pageID] = [note]
            if failCreateAfterCommit { failCreateAfterCommit = false; throw NotionFailure("timeout") }
            return page!
        }
        if endpoint == "/v1/blocks/" + noteID { return note }
        let parts = endpoint.split(separator: "?")[0].split(separator: "/")
        guard parts.count == 4, parts[3] == "children" else { throw NotionFailure("Unexpected fake endpoint") }
        let id = String(parts[2])
        if method == "GET" {
            let components = URLComponents(string: "https://example.invalid" + endpoint)
            let start = components?.queryItems?.first(where: { $0.name == "start_cursor" })?.value.flatMap(Int.init) ?? 0
            let all = blocks[id] ?? []
            let end = min(start + 100, all.count)
            var result: [String: Any] = ["results": Array(all[start..<end]), "has_more": end < all.count]
            if end < all.count { result["next_cursor"] = String(end) }
            return result
        }
        mutations += 1
        let children = body!["children"] as! [[String: Any]]
        largestBatch = max(largestBatch, children.count)
        let isChunks = children.first?["type"] as? String == "paragraph"
        if isChunks && rejectBatch { rejectBatch = false; throw NotionFailure("denied", definiteRejection: true) }
        if isChunks && failChunkBeforeCommit { failChunkBeforeCommit = false; throw NotionFailure("timeout") }
        let inserted = children.map { value -> [String: Any] in
            var block = value; block["id"] = UUID().uuidString; return block
        }
        blocks[id, default: []] += inserted
        if isChunks && failChunkAfterCommit { failChunkAfterCommit = false; throw NotionFailure("timeout") }
        return ["results": inserted]
    }
}

@Suite("Notion export reconciliation")
struct NotionExportTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "[自分] 00:00:01 <meeting-notes> is literal text 😃".write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        return directory
    }
    private let date = NotionNote.parseDate("2026-10-27T10:00:00Z")!

    @Test("Existing agenda survives export and completed retries do not mutate")
    func appendAndRetry() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let api = FakeNotionAPI()
        let service = NotionMeetingNotes(configuration: .init(), request: api.call)
        _ = try service.export(directory: directory, startedAt: date, selectedNoteID: api.noteID)
        let mutations = api.mutations
        _ = try service.export(directory: directory, startedAt: date, selectedNoteID: api.noteID)
        #expect(api.mutations == mutations)
        #expect(NotionMeetingNotes.plainText(api.blocks[api.notesID]!.first!, type: "paragraph") == "Existing agenda")
        let groupID = api.blocks[api.notesID]!.last!["id"] as! String
        #expect(NotionMeetingNotes.plainText(api.blocks[groupID]!.first!, type: "paragraph").contains("<meeting-notes> is literal text"))
    }

    @Test("A creation timeout that committed is reconciled without a second page")
    func committedCreation() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let api = FakeNotionAPI(); api.failCreateAfterCommit = true
        let service = NotionMeetingNotes(configuration: .init(), request: api.call)
        #expect(throws: (any Error).self) { try service.export(directory: directory, startedAt: date) }
        _ = try service.export(directory: directory, startedAt: date)
        #expect(api.mutations == 3) // one page, one group, one text batch
    }

    @Test("An uncertain creation with no remote match is never blindly repeated")
    func unknownCreation() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let api = FakeNotionAPI(); api.failCreateBeforeCommit = true
        let service = NotionMeetingNotes(configuration: .init(), request: api.call)
        #expect(throws: (any Error).self) { try service.export(directory: directory, startedAt: date) }
        #expect(throws: (any Error).self) { try service.export(directory: directory, startedAt: date) }
        #expect(api.mutations == 1)
    }

    @Test("Committed text batch is reconciled after a timeout")
    func committedBatch() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let api = FakeNotionAPI(); api.failChunkAfterCommit = true
        let service = NotionMeetingNotes(configuration: .init(), request: api.call)
        #expect(throws: (any Error).self) { try service.export(directory: directory, startedAt: date, selectedNoteID: api.noteID) }
        _ = try service.export(directory: directory, startedAt: date, selectedNoteID: api.noteID)
        #expect(api.mutations == 2)
    }

    @Test("An unconfirmed batch is not sent again")
    func unknownBatch() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let api = FakeNotionAPI(); api.failChunkBeforeCommit = true
        let service = NotionMeetingNotes(configuration: .init(), request: api.call)
        #expect(throws: (any Error).self) { try service.export(directory: directory, startedAt: date, selectedNoteID: api.noteID) }
        #expect(throws: (any Error).self) { try service.export(directory: directory, startedAt: date, selectedNoteID: api.noteID) }
        #expect(api.mutations == 2)
    }

    @Test("Changed transcript cannot silently reuse an existing export")
    func changedText() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let api = FakeNotionAPI()
        let service = NotionMeetingNotes(configuration: .init(), request: api.call)
        _ = try service.export(directory: directory, startedAt: date, selectedNoteID: api.noteID)
        try "changed".write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try service.export(directory: directory, startedAt: date, selectedNoteID: api.noteID) }
    }
    @Test("Definite creation rejection can be retried after configuration repair")
    func deniedCreation() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let api = FakeNotionAPI(); api.rejectCreate = true
        let service = NotionMeetingNotes(configuration: .init(), request: api.call)
        #expect(throws: (any Error).self) { try service.export(directory: directory, startedAt: date) }
        _ = try service.export(directory: directory, startedAt: date)
        #expect(api.mutations == 4)
    }
    @Test("Definite text rejection clears pending uncertainty for a safe retry")
    func deniedBatch() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let api = FakeNotionAPI(); api.rejectBatch = true
        let service = NotionMeetingNotes(configuration: .init(), request: api.call)
        #expect(throws: (any Error).self) { try service.export(directory: directory, startedAt: date, selectedNoteID: api.noteID) }
        _ = try service.export(directory: directory, startedAt: date, selectedNoteID: api.noteID)
        #expect(api.mutations == 3)
    }
    @Test("Ambiguous headless export never guesses or writes; explicit note recovers")
    func ambiguousHeadlessExport() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let api = FakeNotionAPI()
        let service = NotionMeetingNotes(configuration: .init()) { method, endpoint, body in
            if endpoint == "/v1/blocks/meeting_notes/query" {
                var second = api.note
                second["id"] = "44444444-4444-4444-8444-444444444444"
                return ["results": [api.note, second]]
            }
            return try api.call(method, endpoint, body)
        }
        do {
            _ = try service.export(directory: directory, startedAt: date)
            Issue.record("Expected ambiguous candidate failure")
        } catch {
            #expect(error.localizedDescription.contains("--note <ID>"))
            #expect(!error.localizedDescription.contains("アプリの選択画面"))
        }
        #expect(api.mutations == 0)
        _ = try service.export(directory: directory, startedAt: date, selectedNoteID: api.noteID)
        #expect(api.mutations == 2)
    }

    @Test("Large transcripts are batched and existing Notes pagination is followed")
    func largeExport() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let text = String(repeating: "日本語😃", count: 25000)
        try text.write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let api = FakeNotionAPI()
        api.blocks[api.notesID] = Array(repeating: api.blocks[api.notesID]!.first!, count: 150)
        let service = NotionMeetingNotes(configuration: .init(), request: api.call)
        _ = try service.export(directory: directory, startedAt: date, selectedNoteID: api.noteID)
        #expect(api.largestBatch <= 50)
        #expect(api.mutations >= 3)
        let groupID = api.blocks[api.notesID]!.last!["id"] as! String
        #expect(api.blocks[groupID]!.map { NotionMeetingNotes.plainText($0, type: "paragraph") }.joined() == text)
    }
    @Test("Saturated date ranges subdivide and duplicate candidate IDs are removed")
    func subdividedQuery() throws {
        let api = FakeNotionAPI()
        var calls = 0
        let service = NotionMeetingNotes(configuration: .init()) { _, _, _ in
            calls += 1
            if calls == 1 { return ["results": Array(repeating: api.note, count: 50)] }
            return ["results": [api.note]]
        }
        let candidates = try service.candidates(startedAt: date)
        #expect(calls == 3)
        #expect(candidates.map(\.id) == [api.noteID])
    }

}
