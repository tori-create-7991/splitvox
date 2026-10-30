import Foundation
import CryptoKit
import Darwin

struct NotionConfiguration: Codable, Equatable {
    var cliPath = ""
    var parentPageID = ""
    var windowMinutes = 10.0
    var dataSourceID = ""
    var dateProperty = "Start Date"
}

struct NotionNote: Identifiable {
    let id: String
    let title: String
    let notesID: String
    let date: Date

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func decode(_ block: [String: Any]) throws -> NotionNote {
        guard let id = block["id"] as? String,
              let meeting = block["meeting_notes"] as? [String: Any],
              let children = meeting["children"] as? [String: Any],
              let notesID = children["notes_block_id"] as? String else {
            throw NotionFailure("Meeting NoteのNotes欄を取得できませんでした。")
        }
        let recording = meeting["recording"] as? [String: Any]
        let calendar = meeting["calendar_event"] as? [String: Any]
        let timestamp = recording?["start_time"] as? String ?? calendar?["start_time"] as? String ?? block["created_time"] as? String ?? ""
        let title = (meeting["title"] as? [[String: Any]] ?? []).map { ($0["plain_text"] as? String) ?? (($0["text"] as? [String: Any])?["content"] as? String ?? "") }.joined()
        return NotionNote(id: id, title: title.isEmpty ? "無題の会議" : title, notesID: notesID, date: parseDate(timestamp) ?? .distantPast)
    }

    static func candidates(_ response: [String: Any], startedAt: Date, window: TimeInterval) throws -> [NotionNote] {
        guard let blocks = response["results"] as? [[String: Any]] else { throw NotionFailure("ノート検索の応答が不正です。") }
        guard blocks.count < 50, response["has_more"] as? Bool != true else {
            throw NotionFailure("検索結果が上限に達したため自動作成を停止しました。CLIで対象ノートを指定してください。")
        }
        // Notes IDs are optional on unrelated/unfinished notes. Filter by
        // metadata first; only a plausible target requires a writable Notes tab.
        return try blocks.compactMap { block -> NotionNote? in
            guard let meeting = block["meeting_notes"] as? [String: Any] else { throw NotionFailure("ノート検索のメタデータが不正です。") }
            let recording = meeting["recording"] as? [String: Any]
            let calendar = meeting["calendar_event"] as? [String: Any]
            let raw = recording?["start_time"] as? String ?? calendar?["start_time"] as? String ?? block["created_time"] as? String ?? ""
            guard let date = parseDate(raw) else { throw NotionFailure("ノートの開始日時を確認できませんでした。") }
            guard abs(date.timeIntervalSince(startedAt)) <= window else { return nil }
            return try decode(block)
        }.sorted { $0.date < $1.date }
    }
}

private struct NotionJournal: Codable {
    var sessionID = UUID().uuidString
    var startedAt: Date
    var digest: String
    var phase = "ready"
    var pageID: String?
    var noteID: String?
    var pendingCount: Int?
    var completed = false
    var dataSourceID: String?
    var pendingDateProperty: String?
}

/// All mutations are journaled before dispatch. An uncertain request is never
/// repeated merely because a local process timed out.
final class NotionMeetingNotes {
    typealias Request = (String, String, [String: Any]?) throws -> [String: Any]
    private let request: Request
    let configuration: NotionConfiguration

    init(configuration: NotionConfiguration, request: @escaping Request) {
        self.configuration = configuration
        self.request = request
    }

    convenience init(configuration: NotionConfiguration) throws {
        let cli = try NotionCLI(path: configuration.cliPath)
        self.init(configuration: configuration, request: cli.call)
    }

    private var dataSource: NotionDataSource? {
        configuration.dataSourceID.isEmpty ? nil : NotionDataSource(configuration: configuration, request: request, children: children)
    }

    func candidates(startedAt: Date) throws -> [NotionNote] {
        if let dataSource { return try dataSource.candidates(startedAt: startedAt) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        // Includes UTC boundaries and notes prepared up to 30 days beforehand.
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func load(_ from: Date, _ to: Date) throws -> [NotionNote] {
            let dates: [String: Any] = ["type": "exact", "value": ["type": "daterange", "start_date": formatter.string(from: from), "end_date": formatter.string(from: to)]]
            let filter: [String: Any] = ["operator": "and", "filters": [["property": "created_time", "filter": ["operator": "date_is_within", "value": dates]]]]
            let response = try request("POST", "/v1/blocks/meeting_notes/query", ["filter": filter, "limit": 50])
            guard let blocks = response["results"] as? [[String: Any]] else { throw NotionFailure("ノート検索の応答が不正です。") }
            if blocks.count >= 50 || response["has_more"] as? Bool == true {
                let days = Int(to.timeIntervalSince(from) / 86400)
                guard days > 0 else { throw NotionFailure("1日の検索結果が上限に達しました。CLIで対象ノートを指定してください。") }
                let middle = from.addingTimeInterval(Double(days / 2) * 86400)
                return try load(from, middle) + load(middle.addingTimeInterval(86400), to)
            }
            return try NotionNote.candidates(response, startedAt: startedAt, window: configuration.windowMinutes * 60)
        }
        let day = utcCalendar.startOfDay(for: startedAt)
        let values = try load(day.addingTimeInterval(-30 * 86400), day.addingTimeInterval(86400))
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
    }

    static func chunks(_ text: String) -> [String] {
        var result: [String] = [], part = "", units = 0
        for scalar in text.unicodeScalars {
            let length = scalar.value > 0xffff ? 2 : 1
            if units + length > 1800 { result.append(part); part = ""; units = 0 }
            part.unicodeScalars.append(scalar); units += length
        }
        if !part.isEmpty { result.append(part) }
        return result
    }

    static func newNoteMarkdown() -> String {
        "<meeting-notes>Splitvox 会議メモ<meeting-notes-section-notes>文字起こし</meeting-notes-section-notes></meeting-notes>"
    }

    static func plainText(_ block: [String: Any], type: String) -> String {
        let content = block[type] as? [String: Any] ?? [:]
        return (content["rich_text"] as? [[String: Any]] ?? []).map {
            ($0["plain_text"] as? String) ?? (($0["text"] as? [String: Any])?["content"] as? String ?? "")
        }.joined()
    }

    private static func rich(_ text: String) -> [[String: Any]] { [["type": "text", "text": ["content": text]]] }

    private func children(_ id: String) throws -> [[String: Any]] {
        var result: [[String: Any]] = [], cursor: String?
        repeat {
            var components = URLComponents()
            components.path = "/v1/blocks/\(id)/children"
            components.queryItems = [URLQueryItem(name: "page_size", value: "100")]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "start_cursor", value: cursor)) }
            let response = try request("GET", components.string!, nil)
            guard let values = response["results"] as? [[String: Any]] else { throw NotionFailure("Notes欄の読み戻しに失敗しました。") }
            result += values
            if response["has_more"] as? Bool == true {
                guard let next = response["next_cursor"] as? String, next != cursor else { throw NotionFailure("ページ送りの応答が不正です。") }
                cursor = next
            } else { cursor = nil }
        } while cursor != nil
        return result
    }

    private func searchPage(marker: String) throws -> String? {
        let response = try request("POST", "/v1/search", ["query": marker, "page_size": 100])
        guard let values = response["results"] as? [[String: Any]], response["has_more"] as? Bool != true else { throw NotionFailure("作成済みページの照合を完了できませんでした。") }
        let matches = values.filter { page in
            guard let props = page["properties"] as? [String: Any] else { return false }
            return props.values.contains { property in
                guard let field = property as? [String: Any], let title = field["title"] as? [[String: Any]] else { return false }
                return title.map { ($0["plain_text"] as? String) ?? (($0["text"] as? [String: Any])?["content"] as? String ?? "") }.joined().contains(marker)
            }
        }
        guard matches.count <= 1 else { throw NotionFailure("同じセッションのページが複数あります。手動で確認してください。") }
        return matches.first?["id"] as? String
    }

    func export(directory: URL, startedAt: Date, selectedNoteID: String? = nil) throws -> String {
        let lock = directory.appendingPathComponent(".notion-sync.lock")
        let descriptor = Darwin.open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw NotionFailure("この録音は送信中、または前回の処理が中断されています。送信状態を確認してください。") }
        close(descriptor)
        defer { try? FileManager.default.removeItem(at: lock) }
        let transcript = try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NotionFailure("文字起こしが空のため送信しません。") }
        let digest = SHA256.hash(data: Data(transcript.utf8)).map { String(format: "%02x", $0) }.joined()
        let journalURL = directory.appendingPathComponent(".notion-sync.json")
        var state: NotionJournal
        if FileManager.default.fileExists(atPath: journalURL.path) {
            state = try JSONDecoder().decode(NotionJournal.self, from: Data(contentsOf: journalURL))
            guard state.digest == digest else { throw NotionFailure("前回から文字起こしが変更されています。送信先を確認してください。") }
        } else { state = NotionJournal(startedAt: startedAt, digest: digest) }
        func save() throws { try JSONEncoder().encode(state).write(to: journalURL, options: .atomic) }
        try save()
        if let selectedNoteID, let bound = state.noteID, bound != selectedNoteID { throw NotionFailure("この録音には別の送信先が記録されています。") }
        if state.completed, let id = state.noteID { return "送信済み: https://www.notion.so/" + id.replacingOccurrences(of: "-", with: "") }
        let destination = dataSource
        let targetID = destination?.id ?? ""
        if let bound = state.dataSourceID {
            guard bound == targetID else { throw NotionFailure("未完了の録音は送信先DBを変更できません。") }
        } else if state.phase == "ready", state.pageID == nil, state.noteID == nil {
            state.dataSourceID = targetID
            try save()
        }
        if let property = state.pendingDateProperty, property != configuration.dateProperty {
            throw NotionFailure("未確定の開始日時更新があります。日時列を変更せず照合してください。")
        }
        if state.noteID == nil {
            if let selectedNoteID {
                guard UUID(uuidString: selectedNoteID) != nil else { throw NotionFailure("Meeting Note IDが不正です。") }
                if let destination {
                    let pageID = try destination.verifyNote(request("GET", "/v1/blocks/\(selectedNoteID)", nil))
                    if let created = state.pageID, UUID(uuidString: created) != UUID(uuidString: pageID) {
                        throw NotionFailure("作成済みページと指定ノートのページが異なります。")
                    }
                }
                state.noteID = selectedNoteID
                try save()
            } else if state.phase == "ready" {
                let matches = try candidates(startedAt: state.startedAt)
                if matches.count > 1 { throw NotionFailure("候補が複数あります。dry-runで確認してCLIの--note <ID>で指定してください。") }
                state.noteID = matches.first?.id
                try save()
            }
        }
        if state.noteID == nil {
            if state.pageID == nil, state.phase == "creating" {
                // Old journals may have created a workspace page. Reconcile in
                // their original scope before applying a new DB membership check.
                if state.dataSourceID != nil, let destination {
                    state.pageID = try destination.findPage(marker: state.sessionID)
                } else { state.pageID = try searchPage(marker: state.sessionID) }
                guard state.pageID != nil else { throw NotionFailure("新規作成の結果が不明です。重複を避けるため再作成を停止しました。NotionでセッションID \(state.sessionID) を検索してください。") }
                try save()
            }
            if state.pageID == nil {
                let parent = configuration.parentPageID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard parent.isEmpty || UUID(uuidString: parent) != nil else { throw NotionFailure("親ページIDが不正です。") }
                let title = "Splitvox \(ISO8601DateFormatter().string(from: state.startedAt)) [\(state.sessionID)]"
                let body: [String: Any]
                if let destination { body = try destination.creationBody(title: title, startedAt: state.startedAt) }
                else { body = ["parent": parent.isEmpty ? ["workspace": true] : ["page_id": parent], "properties": ["title": ["title": Self.rich(title)]], "markdown_version": "v2", "markdown": Self.newNoteMarkdown()] }
                state.phase = "creating"; try save()
                let page: [String: Any]
                do {
                    page = try request("POST", "/v1/pages", body)
                } catch {
                    if (error as? NotionFailure)?.definiteRejection == true { state.phase = "ready"; try save() }
                    throw error
                }
                guard let id = page["id"] as? String else { throw NotionFailure("ページ作成応答が不正です。") }
                state.pageID = id; try save()
            }
            if let destination { try destination.verifyPage(state.pageID!) }
            let blocks = try children(state.pageID!)
            let notes = blocks.filter { $0["type"] as? String == "meeting_notes" }
            guard notes.count <= 1 else { throw NotionFailure("ページにMeeting Noteが複数あります。--note <ID>で指定してください。") }
            guard let id = notes.first?["id"] as? String else { throw NotionFailure("正式なMeeting Noteが作成されませんでした。Markdown v2の対応状況を確認してください。") }
            state.noteID = id; state.phase = "ready"; try save()
        }
        let block = try request("GET", "/v1/blocks/\(state.noteID!)", nil)
        if let destination {
            let pageID = try destination.verifyNote(block)
            if let created = state.pageID, UUID(uuidString: created) != UUID(uuidString: pageID) {
                throw NotionFailure("作成済みページと指定ノートのページが異なります。")
            }
        }
        state.dataSourceID = targetID; try save()
        let note = try NotionNote.decode(block)
        let marker = "Splitvox \(directory.lastPathComponent) [\(state.sessionID)]"
        var groups = try children(note.notesID).filter { $0["type"] as? String == "toggle" && Self.plainText($0, type: "toggle") == marker }
        guard groups.count <= 1 else { throw NotionFailure("同じセッションの書き込みが複数あります。") }
        if groups.isEmpty {
            guard state.phase != "container" else { throw NotionFailure("追記先の作成結果が不明です。Notionを確認してから再試行してください。") }
            state.phase = "container"; try save()
            do {
                _ = try request("PATCH", "/v1/blocks/\(note.notesID)/children", ["children": [["object": "block", "type": "toggle", "toggle": ["rich_text": Self.rich(marker)]]]])
            } catch {
                if (error as? NotionFailure)?.definiteRejection == true { state.phase = "ready"; try save() }
                throw error
            }
            groups = try children(note.notesID).filter { $0["type"] as? String == "toggle" && Self.plainText($0, type: "toggle") == marker }
        }
        guard groups.count == 1, let groupID = groups.first?["id"] as? String else { throw NotionFailure("追記先の読み戻しに失敗しました。") }
        if state.pendingDateProperty == nil { state.phase = "writing"; try save() }
        let chunks = Self.chunks(transcript)
        var stored = try children(groupID)
        func validate() throws {
            guard stored.count <= chunks.count,
                  stored.enumerated().allSatisfy({ $0.element["type"] as? String == "paragraph" && Self.plainText($0.element, type: "paragraph") == chunks[$0.offset] }) else {
                throw NotionFailure("送信先の内容が変更されています。既存の内容を保護するため停止しました。")
            }
        }
        try validate()
        if let pending = state.pendingCount, stored.count < pending { throw NotionFailure("前回の追記結果が不明です。重複を避けるため送信を停止しました。") }
        while stored.count < chunks.count {
            let end = min(stored.count + 50, chunks.count)
            let batch = chunks[stored.count..<end].map { ["object": "block", "type": "paragraph", "paragraph": ["rich_text": Self.rich($0)]] as [String: Any] }
            state.pendingCount = end; try save()
            do {
                _ = try request("PATCH", "/v1/blocks/\(groupID)/children", ["children": batch])
            } catch {
                if (error as? NotionFailure)?.definiteRejection == true { state.pendingCount = nil; try save() }
                throw error
            }
            stored = try children(groupID)
            try validate()
            guard stored.count >= end else { throw NotionFailure("送信内容の読み戻しが一致しません。") }
            state.pendingCount = nil; try save()
        }
        if let destination, let pageID = state.pageID {
            // Native meeting-note creation can replace the supplied date with
            // its creation time. Restore only this export's newly created row,
            // after all Notes mutations, and reconcile an uncertain PATCH.
            if try destination.recordingDate(pageID).map(NotionDataSource.dateText) != NotionDataSource.dateText(state.startedAt) {
                guard state.pendingDateProperty == nil else { throw NotionFailure("開始日時更新の結果が不明です。再更新せずNotionを確認してください。") }
                state.phase = "dating"; state.pendingDateProperty = configuration.dateProperty; try save()
                do { try destination.setRecordingDate(pageID, startedAt: state.startedAt) }
                catch {
                    if (error as? NotionFailure)?.definiteRejection == true {
                        state.phase = "writing"; state.pendingDateProperty = nil; try save()
                    }
                    throw error
                }
                guard try destination.recordingDate(pageID).map(NotionDataSource.dateText) == NotionDataSource.dateText(state.startedAt) else { throw NotionFailure("保存した開始日時の読み戻しが一致しません。") }
            }
            state.pendingDateProperty = nil
        }
        state.completed = true; state.phase = "complete"; try save()
        return "送信完了: https://www.notion.so/" + note.id.replacingOccurrences(of: "-", with: "")
    }
}
