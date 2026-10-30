import Foundation

enum NotionCommand {
    /// Pure arguments only. Normal export never reads host-app preferences.
    static func configuration(_ arguments: [String], base: NotionConfiguration = NotionConfiguration()) throws -> NotionConfiguration {
        var config = base
        let valueFlags: Set<String> = ["--ntn", "--parent-page", "--window-minutes", "--data-source", "--date-property", "--notion-sync", "--started-at", "--note"]
        let switches: Set<String> = ["--write", "--notion-status"]
        var index = 0, seen: Set<String> = []
        while index < arguments.count {
            let flag = arguments[index]
            guard valueFlags.contains(flag) || switches.contains(flag) else {
                throw NotionFailure("不明な引数です: " + flag)
            }
            guard seen.insert(flag).inserted else { throw NotionFailure("引数が重複しています: " + flag) }
            if switches.contains(flag) { index += 1; continue }
            guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
                throw NotionFailure("引数に値が必要です: " + flag)
            }
            let value = arguments[index + 1]
            switch flag {
            case "--ntn": config.cliPath = value
            case "--parent-page": config.parentPageID = value
            case "--data-source": config.dataSourceID = value
            case "--date-property": config.dateProperty = value
            case "--window-minutes":
                guard let minutes = Double(value), minutes.isFinite, (1...120).contains(minutes) else {
                    throw NotionFailure("--window-minutesは1〜120の有限数で指定してください。")
                }
                config.windowMinutes = minutes
            default: break // Operation values are consumed by run after validation.
            }
            index += 2
        }
        if arguments.contains("--data-source") || !config.dataSourceID.isEmpty {
            guard let id = UUID(uuidString: config.dataSourceID), config.parentPageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NotionFailure("--data-sourceにはUUIDを指定し、--parent-pageとは併用しないでください。")
            }
            guard !config.dateProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NotionFailure("--date-propertyには日時列名を指定してください。")
            }
            config.dataSourceID = id.uuidString.lowercased()
        } else if arguments.contains("--date-property") {
            throw NotionFailure("--date-propertyには--data-sourceが必要です。")
        }
        return config
    }

    static func run(_ arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        do {
            let config = try configuration(arguments)
            let cli = try NotionCLI(path: config.cliPath)
            if arguments.contains("--notion-status") {
                let data = try JSONSerialization.data(withJSONObject: ["mode": "standalone_cli_configuration", "cli": cli.executable, "windowMinutes": config.windowMinutes, "parentConfigured": !config.parentPageID.isEmpty, "dataSource": config.dataSourceID, "dateProperty": config.dataSourceID.isEmpty ? "" : config.dateProperty], options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return 0
            }
            guard let directory = value("--notion-sync") else { throw NotionFailure("--notion-sync <録音フォルダ>が必要です。") }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let url = URL(fileURLWithPath: directory)
            let startedAt = value("--started-at").flatMap(NotionNote.parseDate) ?? formatter.date(from: url.lastPathComponent)
            guard let startedAt else { throw NotionFailure("--started-at <ISO8601日時>を指定してください。") }
            let service = NotionMeetingNotes(configuration: config, request: cli.call)
            if arguments.contains("--write") {
                let message = try service.export(directory: url, startedAt: startedAt, selectedNoteID: value("--note"))
                ExportLog.write("Notion: " + message, directory: url)
                print(message)
            } else {
                let notes = try service.candidates(startedAt: startedAt)
                print("dry-run: \(notes.count) candidate(s); " + (notes.isEmpty ? "create native Meeting Note" : "append/select existing Meeting Note"))
                for note in notes { print("\(note.id)\t\(ISO8601DateFormatter().string(from: note.date))\t\(note.title)") }
                print("No writes performed. Add --write to send transcript.md; use --note <id> to select.")
            }
            return 0
        } catch {
            if arguments.contains("--write"), let directory = value("--notion-sync") {
                ExportLog.write("Notion: " + error.localizedDescription, directory: URL(fileURLWithPath: directory))
            }
            fputs("Notion: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
