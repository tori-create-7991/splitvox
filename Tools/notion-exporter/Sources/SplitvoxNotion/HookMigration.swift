import Foundation

/// Used only by the explicit migration subcommand, never by normal export.
struct LegacyNotionPreferences: Codable {
    var enabled: Bool
    var cliPath: String
    var parentPageID: String
    var windowMinutes: Double
}

private struct HookDocument: Decodable {
    let version: Int
    let hooks: [Entry]
    struct Entry: Decodable {
        let id: UUID
        let name: String
        let enabled: Bool
        let event: String
        let command: String
        let timeoutSeconds: Double
    }
    func validate() throws {
        guard version == 1, Set(hooks.map(\.id)).count == hooks.count,
              hooks.allSatisfy({ ["recording_started", "recording_stopped"].contains($0.event)
                  && $0.timeoutSeconds.isFinite && (1...3600).contains($0.timeoutSeconds)
                  && (!$0.enabled || (!$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) }) else {
            throw NotionFailure("フック設定が不正または非対応です。変更せず停止しました。")
        }
    }
}

enum HookMigration {
    struct Result {
        let document: Data
        let changedHooks: Int
    }
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    static func legacyCommand(_ configuration: LegacyNotionPreferences, executable: String) -> String {
        quote(executable)
            + " --notion-sync \"$SPLITVOX_SESSION_DIRECTORY\" --write"
            + " --started-at \"$SPLITVOX_RECORDING_STARTED_AT\""
            + " --ntn " + quote(configuration.cliPath)
            + " --parent-page " + quote(configuration.parentPageID)
            + " --window-minutes " + quote(String(configuration.windowMinutes))
    }
    static func prepare(document: Data?, legacy: Data?, startCommand: String, stopCommand: String,
                        oldExecutable: String, newExecutable: String) throws -> Result {
        guard oldExecutable.hasPrefix("/"), newExecutable.hasPrefix("/"), oldExecutable != newExecutable,
              !oldExecutable.contains("\0"), !newExecutable.contains("\0") else {
            throw NotionFailure("旧アプリと新CLIには異なる絶対パスを指定してください。")
        }
        func legacyValue() throws -> LegacyNotionPreferences? {
            guard let legacy else { return nil }
            var value = try JSONDecoder().decode(LegacyNotionPreferences.self, from: legacy)
            value.windowMinutes = value.windowMinutes.isFinite ? min(120, max(1, value.windowMinutes)) : 10
            return value
        }
        var raw: [String: Any]
        var changed = 0
        if let document {
            try JSONDecoder().decode(HookDocument.self, from: document).validate()
            guard let decoded = try JSONSerialization.jsonObject(with: document) as? [String: Any] else {
                throw NotionFailure("フック設定を読み込めません。")
            }
            raw = decoded
        } else {
            var hooks: [[String: Any]] = []
            for (event, command) in [("recording_started", startCommand), ("recording_stopped", stopCommand)]
                where !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hooks.append(["id": UUID().uuidString, "name": "Migrated command", "enabled": true,
                              "event": event, "command": command, "timeoutSeconds": 15])
            }
            if let value = try legacyValue() {
                hooks.append(["id": UUID().uuidString, "name": "Migrated export", "enabled": value.enabled,
                              "event": "recording_stopped", "command": legacyCommand(value, executable: newExecutable),
                              "timeoutSeconds": 600])
                changed += 1
            }
            raw = ["version": 1, "hooks": hooks]
        }
        var hooks = raw["hooks"] as! [[String: Any]]
        for index in hooks.indices {
            let command = hooks[index]["command"] as! String
            let refersToOldApp = command.contains(oldExecutable) || command.contains(quote(oldExecutable))
                || command.contains("Splitvox.app/Contents/MacOS/Splitvox")
            let oldExporterOption = command.contains("--notion-sync") || command.contains("--notion-status")
            guard oldExporterOption && refersToOldApp else { continue }
            guard let value = try legacyValue(), command == legacyCommand(value, executable: oldExecutable) else {
                throw NotionFailure("旧アプリを呼ぶカスタムフックがあります。自動変更せず停止しました（ID: \(hooks[index]["id"] as! String)）。")
            }
            // Preserve every byte of the arguments and all unknown JSON fields.
            hooks[index]["command"] = quote(newExecutable) + command.dropFirst(quote(oldExecutable).count)
            changed += 1
        }
        if let document, changed == 0 { return Result(document: document, changedHooks: 0) }
        raw["hooks"] = hooks
        let output = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        try JSONDecoder().decode(HookDocument.self, from: output).validate()
        return Result(document: output, changedHooks: changed)
    }

    static func run(_ arguments: [String]) throws {
        let flags: Set<String> = ["--migrate-local-hooks", "--write", "--domain", "--old-executable", "--new-executable", "--backup-directory"]
        guard arguments.filter({ $0.hasPrefix("--") }).allSatisfy(flags.contains) else {
            throw NotionFailure("移行モードに不明な引数があります。変更せず停止しました。")
        }
        func value(_ flag: String, default fallback: String? = nil) throws -> String {
            let indices = arguments.indices.filter { arguments[$0] == flag }
            guard indices.count <= 1 else { throw NotionFailure("引数が重複しています: " + flag) }
            if let index = indices.first {
                guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
                    throw NotionFailure("引数に値が必要です: " + flag)
                }
                return arguments[index + 1]
            }
            guard let fallback else { throw NotionFailure("引数が必要です: " + flag) }
            return fallback
        }
        let domain = try value("--domain", default: "io.github.tori-create-7991.splitvox")
        guard !domain.isEmpty, let defaults = UserDefaults(suiteName: domain) else { throw NotionFailure("設定ドメインが不正です。") }
        let old = try value("--old-executable", default: "/Applications/Splitvox.app/Contents/MacOS/Splitvox")
        let new = try value("--new-executable")
        guard FileManager.default.isExecutableFile(atPath: new) else { throw NotionFailure("新CLIを先にインストールしてください。") }
        defaults.synchronize()
        let before = defaults.persistentDomain(forName: domain) ?? [:]
        for key in ["localHooksConfiguration", "notionConfiguration"] where before[key] != nil && !(before[key] is Data) {
            throw NotionFailure("保存済み設定の形式が不正です。変更せず停止しました。")
        }
        let original = before["localHooksConfiguration"] as? Data
        let result = try prepare(document: original, legacy: before["notionConfiguration"] as? Data,
                                 startCommand: before["recordingStartedCommand"] as? String ?? "",
                                 stopCommand: before["recordingStoppedCommand"] as? String ?? "",
                                 oldExecutable: old, newExecutable: new)
        var backupPath: String?
        let shouldWrite = arguments.contains("--write") && result.document != original
        if shouldWrite {
            let fm = FileManager.default
            let defaultBackup = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SplitvoxNotion/Backups").path
            let root = URL(fileURLWithPath: try value("--backup-directory", default: defaultBackup))
                .appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = root.appendingPathComponent("preferences.plist")
            try PropertyListSerialization.data(fromPropertyList: before, format: .binary, options: 0).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            defaults.synchronize()
            guard NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: domain) ?? [:]) else {
                throw NotionFailure("確認中に設定が変更されました。変更せず停止しました。")
            }
            defaults.set(result.document, forKey: "localHooksConfiguration")
            guard defaults.synchronize(), defaults.data(forKey: "localHooksConfiguration") == result.document else {
                throw NotionFailure("設定保存の結果を確認できません。バックアップと保存状態を照合してください。")
            }
            backupPath = file.path
        }
        var summary: [String: Any] = ["changedHooks": result.changedHooks, "applied": shouldWrite,
                                      "dryRun": !arguments.contains("--write")]
        if let backupPath { summary["backupPath"] = backupPath }
        print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))
    }
}
