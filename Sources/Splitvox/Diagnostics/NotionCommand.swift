import Foundation

enum NotionCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var config = PreferenceStore().notionConfiguration
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if let cli = value("--ntn") { config.cliPath = cli }
        if let parent = value("--parent-page") { config.parentPageID = parent }
        do {
            let cli = try NotionCLI(path: config.cliPath)
            if arguments.contains("--notion-status") {
                let data = try JSONSerialization.data(withJSONObject: ["enabled": config.enabled, "cli": cli.executable, "windowMinutes": config.windowMinutes, "parentConfigured": !config.parentPageID.isEmpty], options: [.sortedKeys])
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
                let log = SessionLog(directory: url)
                log.write("Notion: " + message); log.flush()
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
                let log = SessionLog(directory: URL(fileURLWithPath: directory))
                log.write("Notion: " + error.localizedDescription); log.flush()
            }
            fputs("Notion: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
