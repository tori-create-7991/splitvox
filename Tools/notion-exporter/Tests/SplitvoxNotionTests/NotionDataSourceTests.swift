import Foundation
import Testing
@testable import SplitvoxNotion

// Unit/integration: real exporter against a deterministic external API fixture.
private final class DatabaseAPI {
    let sourceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let otherID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let pageID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    let noteID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    let notesID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    let date = NotionNote.parseDate("2026-10-30T01:00:00Z")!
    var config: NotionConfiguration { .init(dataSourceID: sourceID) }
    var schema: [String: Any] = ["Meeting name": ["type": "title"], "Start Date": ["type": "date"]]
    var rows: [[String: Any]] = []
    var blocks: [String: [[String: Any]]] = [:]
    var calls: [(String, String, [String: Any]?)] = []
    var mutations = 0
    var created: [String: Any]?
    var parentSource: String?
    var overrideCreatedDate = false
    var dateTimeoutBeforeCommit = false
    var dateTimeoutAfterCommit = false
    var datePatches = 0
    var createTimeout = false
    var queryPages: [[String: Any]] = []
    var note: [String: Any] {
        ["id": noteID, "type": "meeting_notes", "parent": ["type": "page_id", "page_id": pageID],
         "created_time": "2020-01-01T00:00:00Z",
         "meeting_notes": ["children": ["notes_block_id": notesID]]]
    }
    var row: [String: Any] {
        ["id": pageID, "parent": ["type": "data_source_id", "data_source_id": parentSource ?? sourceID],
         "properties": ["Meeting name": ["title": [["plain_text": "Existing meeting"]]],
                        "Start Date": ["date": ["start": "2026-10-30T01:00:00Z"]]]]
    }
    init() { blocks[notesID] = [] }
    func call(_ method: String, _ endpoint: String, _ body: [String: Any]?) throws -> [String: Any] {
        calls.append((method, endpoint, body))
        if method == "GET", endpoint == "/v1/data_sources/" + sourceID {
            return ["id": sourceID, "properties": schema]
        }
        if endpoint == "/v1/data_sources/" + sourceID + "/query" {
            if !queryPages.isEmpty { return queryPages.removeFirst() }
            let filter = body?["filter"] as? [String: Any] ?? [:]
            if filter["title"] != nil { return ["results": created.map { [$0] } ?? [], "has_more": false] }
            return ["results": rows, "has_more": false]
        }
        if endpoint == "/v1/pages", method == "POST" {
            mutations += 1
            created = ["id": pageID, "parent": body!["parent"]!, "properties": body!["properties"]!]
            if overrideCreatedDate {
                var props = created!["properties"] as! [String: Any]
                props["Start Date"] = ["date": ["start": "2026-10-30T01:44:00Z"]]
                created!["properties"] = props
            }
            blocks[pageID] = [note]
            if createTimeout { createTimeout = false; throw NotionFailure("timeout") }
            return created!
        }
        if method == "PATCH", endpoint == "/v1/pages/" + pageID {
            mutations += 1; datePatches += 1
            if dateTimeoutBeforeCommit { dateTimeoutBeforeCommit = false; throw NotionFailure("timeout") }
            var props = created!["properties"] as! [String: Any]
            for (key, value) in body!["properties"] as! [String: Any] { props[key] = value }
            created!["properties"] = props
            if dateTimeoutAfterCommit { dateTimeoutAfterCommit = false; throw NotionFailure("timeout") }
            return created!
        }
        if method == "GET", endpoint == "/v1/pages/" + pageID { return created ?? row }
        if method == "GET", endpoint == "/v1/blocks/" + noteID { return note }
        let parts = endpoint.split(separator: "?")[0].split(separator: "/")
        if parts.count == 4, parts[3] == "children" {
            let id = String(parts[2])
            if method == "GET" { return ["results": blocks[id] ?? [], "has_more": false] }
            mutations += 1
            let values = (body!["children"] as! [[String: Any]]).map { value -> [String: Any] in
                var block = value; block["id"] = UUID().uuidString; return block
            }
            blocks[id, default: []] += values
            return ["results": values]
        }
        throw NotionFailure("Unexpected endpoint: " + endpoint)
    }
    func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "Synthetic DB test 日本語 😃".write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        return dir
    }
}

@Suite("Database meeting note export")
struct NotionDataSourceTests {
    @Test("Creates a database row using the schema title and recording date")
    func createRow() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = NotionMeetingNotes(configuration: api.config, request: api.call)
        _ = try service.export(directory: dir, startedAt: api.date)
        let page = try #require(api.created)
        #expect((page["parent"] as? [String: Any])?["data_source_id"] as? String == api.sourceID)
        let props = try #require(page["properties"] as? [String: Any])
        #expect(props["Meeting name"] != nil)
        #expect(((props["Start Date"] as? [String: Any])?["date"] as? [String: Any])?["start"] as? String == "2026-10-30T01:00:00.000Z")
        #expect(props.count == 2)
        #expect(!api.calls.contains { $0.1 == "/v1/blocks/meeting_notes/query" })
        let before = api.calls.count
        _ = try service.export(directory: dir, startedAt: api.date)
        #expect(api.calls.count == before)
    }

    @Test("Queries only the selected data source and follows pagination")
    func candidates() throws {
        let api = DatabaseAPI()
        api.blocks[api.pageID] = [api.note]
        api.queryPages = [["results": [], "has_more": true, "next_cursor": "page2"], ["results": [api.row], "has_more": false]]
        let notes = try NotionMeetingNotes(configuration: api.config, request: api.call).candidates(startedAt: api.date)
        #expect(notes.map(\.id) == [api.noteID])
        #expect(notes.first?.date == api.date) // row Start Date, not old block created_time
        let queries = api.calls.filter { $0.1.hasSuffix("/query") }
        #expect(queries.count == 2)
        #expect(queries.last?.2?["start_cursor"] as? String == "page2")
        let clauses = (queries.first?.2?["filter"] as? [String: Any])?["and"] as? [[String: Any]]
        #expect(clauses?.count == 2)
        #expect(clauses?.first?["property"] as? String == "Start Date")
        #expect(api.mutations == 0)
    }

    @Test("Missing or mistyped schema stops before any mutation")
    func schemaFailure() throws {
        for schema: [String: Any] in [[:], ["Meeting name": ["type": "title"], "Start Date": ["type": "rich_text"]]] {
            let api = DatabaseAPI(), dir = try api.fixture()
            defer { try? FileManager.default.removeItem(at: dir) }
            api.schema = schema
            #expect(throws: (any Error).self) {
                try NotionMeetingNotes(configuration: api.config, request: api.call).export(directory: dir, startedAt: api.date)
            }
            #expect(api.mutations == 0)
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(".notion-sync.json"))) as! [String: Any]
            #expect(state["phase"] as? String == "ready")
        }
    }

    @Test("Matching row without a native note fails instead of creating a duplicate")
    func missingNote() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.rows = [api.row]
        #expect(throws: (any Error).self) { try NotionMeetingNotes(configuration: api.config, request: api.call).export(directory: dir, startedAt: api.date) }
        #expect(api.mutations == 0)
    }

    @Test("Explicit note outside the selected database is never written")
    func wrongDatabase() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.parentSource = api.otherID
        #expect(throws: (any Error).self) { try NotionMeetingNotes(configuration: api.config, request: api.call).export(directory: dir, startedAt: api.date, selectedNoteID: api.noteID) }
        #expect(api.mutations == 0)
    }

    @Test("Creation timeout reconciles with a scoped marker query")
    func creationRecovery() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.createTimeout = true
        let service = NotionMeetingNotes(configuration: api.config, request: api.call)
        #expect(throws: (any Error).self) { try service.export(directory: dir, startedAt: api.date) }
        _ = try service.export(directory: dir, startedAt: api.date)
        #expect(api.mutations == 3)
        #expect(api.calls.contains { ($0.2?["filter"] as? [String: Any])?["title"] != nil })
    }

    @Test("Unfinished bound export cannot switch to another destination or workspace")
    func destinationBinding() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.createTimeout = true
        #expect(throws: (any Error).self) { try NotionMeetingNotes(configuration: api.config, request: api.call).export(directory: dir, startedAt: api.date) }
        var changed = api.config; changed.dataSourceID = api.otherID
        for config in [changed, NotionConfiguration()] {
            #expect(throws: (any Error).self) { try NotionMeetingNotes(configuration: config, request: api.call).export(directory: dir, startedAt: api.date) }
        }
        #expect(api.mutations == 1)
    }

    @Test("Pagination cycles are rejected")
    func cursorCycle() throws {
        let api = DatabaseAPI()
        api.queryPages = ["a", "b", "a"].map { ["results": [], "has_more": true, "next_cursor": $0] }
        #expect(throws: (any Error).self) { try NotionMeetingNotes(configuration: api.config, request: api.call).candidates(startedAt: api.date) }
        #expect(api.mutations == 0)
    }
    @Test("Rejected explicit DB note does not bind the journal to a wrong note")
    func rejectedSelectionDoesNotBind() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.parentSource = api.otherID
        #expect(throws: (any Error).self) { try NotionMeetingNotes(configuration: api.config, request: api.call).export(directory: dir, startedAt: api.date, selectedNoteID: api.noteID) }
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(".notion-sync.json"))) as! [String: Any]
        #expect(state["noteID"] == nil)
        api.parentSource = nil
        _ = try NotionMeetingNotes(configuration: api.config, request: api.call).export(directory: dir, startedAt: api.date, selectedNoteID: api.noteID)
        #expect(api.mutations == 2)
    }

    @Test("Existing DB row is appended using its recording date")
    func appendToRow() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.rows = [api.row]; api.blocks[api.pageID] = [api.note]
        _ = try NotionMeetingNotes(configuration: api.config, request: api.call).export(directory: dir, startedAt: api.date)
        #expect(api.created == nil)
        #expect(api.mutations == 2)
    }

    @Test("Legacy uncertain creation retains global recovery and rejects an outside page")
    func legacyUncertainCreation() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.createTimeout = true
        #expect(throws: (any Error).self) { try NotionMeetingNotes(configuration: api.config, request: api.call).export(directory: dir, startedAt: api.date) }
        let url = dir.appendingPathComponent(".notion-sync.json")
        var state = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        state.removeValue(forKey: "dataSourceID")
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        api.created?["parent"] = ["type": "workspace", "workspace": true]
        var searchedGlobally = false
        let service = NotionMeetingNotes(configuration: api.config) { method, path, body in
            if path == "/v1/search" { searchedGlobally = true; return ["results": [api.created!], "has_more": false] }
            return try api.call(method, path, body)
        }
        #expect(throws: (any Error).self) { try service.export(directory: dir, startedAt: api.date) }
        #expect(searchedGlobally)
        #expect(api.mutations == 1)
    }

    @Test("Explicit note selection also rejects an invalid destination schema")
    func explicitSchemaFailure() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.schema = [:]
        #expect(throws: (any Error).self) { try NotionMeetingNotes(configuration: api.config, request: api.call).export(directory: dir, startedAt: api.date, selectedNoteID: api.noteID) }
        #expect(api.mutations == 0)
    }

    @Test("Uncertain creation with multiple native notes requires explicit selection")
    func ambiguousRecovery() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.createTimeout = true
        let service = NotionMeetingNotes(configuration: api.config, request: api.call)
        #expect(throws: (any Error).self) { try service.export(directory: dir, startedAt: api.date) }
        var second = api.note; second["id"] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        api.blocks[api.pageID] = [api.note, second]
        #expect(throws: (any Error).self) { try service.export(directory: dir, startedAt: api.date) }
        #expect(api.mutations == 1)
        _ = try service.export(directory: dir, startedAt: api.date, selectedNoteID: api.noteID)
        #expect(api.mutations == 3)
    }

    @Test("New native note date override is restored before export completes")
    func restoreNativeDate() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.overrideCreatedDate = true
        _ = try NotionMeetingNotes(configuration: api.config, request: api.call).export(directory: dir, startedAt: api.date)
        let props = api.created!["properties"] as! [String: [String: Any]]
        #expect((props["Start Date"]?["date"] as? [String: Any])?["start"] as? String == "2026-10-30T01:00:00.000Z")
        #expect(api.datePatches == 1)
    }

    @Test("Committed date repair is reconciled after a timeout without another patch")
    func committedDateRepair() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.overrideCreatedDate = true; api.dateTimeoutAfterCommit = true
        let service = NotionMeetingNotes(configuration: api.config, request: api.call)
        #expect(throws: (any Error).self) { try service.export(directory: dir, startedAt: api.date) }
        _ = try service.export(directory: dir, startedAt: api.date)
        #expect(api.datePatches == 1)
    }

    @Test("Unconfirmed date repair stops instead of repeating a mutation")
    func unknownDateRepair() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.overrideCreatedDate = true; api.dateTimeoutBeforeCommit = true
        let service = NotionMeetingNotes(configuration: api.config, request: api.call)
        #expect(throws: (any Error).self) { try service.export(directory: dir, startedAt: api.date) }
        #expect(throws: (any Error).self) { try service.export(directory: dir, startedAt: api.date) }
        #expect(api.datePatches == 1)
    }

    @Test("Date repair preserves recording milliseconds")
    func fractionalDateRepair() throws {
        let api = DatabaseAPI(), dir = try api.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.overrideCreatedDate = true
        let date = NotionNote.parseDate("2026-10-30T01:00:00.123Z")!
        _ = try NotionMeetingNotes(configuration: api.config, request: api.call).export(directory: dir, startedAt: date)
        let props = api.created!["properties"] as! [String: [String: Any]]
        let raw = (props["Start Date"]?["date"] as! [String: Any])["start"] as! String
        #expect(NotionNote.parseDate(raw) == date)
    }

}
