import Foundation

/// Database-only reads and creation metadata. It never mutates schema or content.
struct NotionDataSource {
    let configuration: NotionConfiguration
    let request: NotionMeetingNotes.Request
    let children: (String) throws -> [[String: Any]]
    var id: String { UUID(uuidString: configuration.dataSourceID)?.uuidString.lowercased() ?? configuration.dataSourceID }

    private func schema() throws -> String {
        guard UUID(uuidString: id) != nil,
              configuration.parentPageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.dateProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotionFailure("DB保存先のUUID・日時列・親ページの指定を確認してください。")
        }
        let response = try request("GET", "/v1/data_sources/\(id)", nil)
        guard let properties = response["properties"] as? [String: [String: Any]],
              properties[configuration.dateProperty]?["type"] as? String == "date" else {
            throw NotionFailure("指定DBにdate型の日時列がありません: " + configuration.dateProperty)
        }
        let titles = properties.filter { $0.value["type"] as? String == "title" }.map(\.key)
        guard titles.count == 1 else { throw NotionFailure("DBのタイトル列を一意に確認できませんでした。") }
        return titles[0]
    }

    private func query(filter: [String: Any]) throws -> [[String: Any]] {
        var rows: [[String: Any]] = [], cursor: String?, seen: Set<String> = []
        repeat {
            var body: [String: Any] = ["filter": filter, "page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let response = try request("POST", "/v1/data_sources/\(id)/query", body)
            guard let values = response["results"] as? [[String: Any]], let more = response["has_more"] as? Bool else {
                throw NotionFailure("DB検索の応答が不正です。")
            }
            rows += values
            if more {
                guard let next = response["next_cursor"] as? String, !next.isEmpty, seen.insert(next).inserted else {
                    throw NotionFailure("DB検索のページ送りを完了できませんでした。")
                }
                cursor = next
            } else { cursor = nil }
        } while cursor != nil
        return rows
    }

    private func verifyMembership(_ page: [String: Any]) throws {
        guard let parent = page["parent"] as? [String: Any],
              parent["type"] as? String == "data_source_id",
              let raw = parent["data_source_id"] as? String,
              UUID(uuidString: raw) == UUID(uuidString: id),
              page["in_trash"] as? Bool != true, page["archived"] as? Bool != true else {
            throw NotionFailure("送信先は指定されたDB内の有効なページではありません。")
        }
    }

    func verifyPage(_ pageID: String) throws {
        guard UUID(uuidString: pageID) != nil else { throw NotionFailure("ページIDが不正です。") }
        try verifyMembership(request("GET", "/v1/pages/\(pageID)", nil))
    }

    func verifyNote(_ note: [String: Any]) throws {
        _ = try schema()
        var block = note, seen: Set<String> = []
        for _ in 0..<32 {
            guard let parent = block["parent"] as? [String: Any] else { break }
            if parent["type"] as? String == "page_id", let pageID = parent["page_id"] as? String {
                try verifyPage(pageID); return
            }
            guard parent["type"] as? String == "block_id", let blockID = parent["block_id"] as? String,
                  UUID(uuidString: blockID) != nil, seen.insert(blockID).inserted else { break }
            block = try request("GET", "/v1/blocks/\(blockID)", nil)
        }
        throw NotionFailure("Meeting Noteが指定DBに属することを確認できませんでした。")
    }

    func candidates(startedAt: Date) throws -> [NotionNote] {
        let titleProperty = try schema()
        let formatter = ISO8601DateFormatter()
        let window = configuration.windowMinutes * 60
        let clauses: [[String: Any]] = [
            ["property": configuration.dateProperty, "date": ["on_or_after": formatter.string(from: startedAt.addingTimeInterval(-window))]],
            ["property": configuration.dateProperty, "date": ["on_or_before": formatter.string(from: startedAt.addingTimeInterval(window))]]
        ]
        var result: [NotionNote] = [], seen: Set<String> = []
        for page in try query(filter: ["and": clauses]) {
            try verifyMembership(page)
            guard let pageID = page["id"] as? String, UUID(uuidString: pageID) != nil,
                  let props = page["properties"] as? [String: [String: Any]],
                  let raw = (props[configuration.dateProperty]?["date"] as? [String: Any])?["start"] as? String,
                  let date = NotionNote.parseDate(raw), abs(date.timeIntervalSince(startedAt)) <= window else {
                throw NotionFailure("DB候補の開始日時またはページIDを確認できませんでした。")
            }
            let title = ((props[titleProperty]?["title"] as? [[String: Any]]) ?? []).map {
                ($0["plain_text"] as? String) ?? (($0["text"] as? [String: Any])?["content"] as? String ?? "")
            }.joined()
            let notes = try children(pageID).filter { $0["type"] as? String == "meeting_notes" }
            guard !notes.isEmpty else { throw NotionFailure("一致するDBページに正式なMeeting Noteがありません。重複作成を停止しました。") }
            for block in notes {
                let note = try NotionNote.decode(block)
                if seen.insert(note.id).inserted {
                    result.append(NotionNote(id: note.id, title: title.isEmpty ? note.title : title, notesID: note.notesID, date: date))
                }
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    func findPage(marker: String) throws -> String? {
        let title = try schema()
        let pages = try query(filter: ["property": title, "title": ["contains": marker]])
        for page in pages { try verifyMembership(page) }
        guard pages.count <= 1 else { throw NotionFailure("同じセッションのDBページが複数あります。") }
        guard let page = pages.first else { return nil }
        guard let pageID = page["id"] as? String, UUID(uuidString: pageID) != nil else { throw NotionFailure("DBページIDが不正です。") }
        return pageID
    }

    func creationBody(title: String, startedAt: Date) throws -> [String: Any] {
        let titleProperty = try schema()
        return ["parent": ["type": "data_source_id", "data_source_id": id],
                "properties": [titleProperty: ["title": [["type": "text", "text": ["content": title]]]],
                               configuration.dateProperty: ["date": ["start": ISO8601DateFormatter().string(from: startedAt)]]],
                "markdown_version": "v2", "markdown": NotionMeetingNotes.newNoteMarkdown()]
    }
}
