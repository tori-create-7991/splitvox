import Foundation

/// Service-agnostic, stable identities survive edits and allow private log correlation.
struct LocalHook: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var enabled = true
    var event: RecordingHookEvent = .stopped
    var command = ""
    var timeoutSeconds: TimeInterval = 15
}

struct LocalHooksDocument: Codable {
    var version = 1
    var hooks: [LocalHook]

    func validate() throws {
        guard version == 1 else { throw LocalHookFailure("ローカルフックの設定バージョンに対応していません。対応するアプリで設定を確認してください。") }
        guard Set(hooks.map(\.id)).count == hooks.count else { throw LocalHookFailure("ローカルフックのIDが重複しています。設定を確認してください。") }
        for hook in hooks {
            guard hook.timeoutSeconds.isFinite, (1...3600).contains(hook.timeoutSeconds) else {
                throw LocalHookFailure("タイムアウトは1〜3600秒で入力してください。")
            }
            guard !hook.enabled || (!hook.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hook.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
                throw LocalHookFailure("有効なローカルフックには名前とコマンドが必要です。")
            }
        }
    }
}

struct LocalHookFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Only constant arguments are quoted into shell source. Session values are
/// passed through the environment and expanded as single, quoted arguments.
enum LocalHookMigration {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func notion(_ configuration: NotionConfiguration, executablePath: String) -> LocalHook {
        let command = quote(executablePath)
            + " --notion-sync \"$SPLITVOX_SESSION_DIRECTORY\" --write"
            + " --started-at \"$SPLITVOX_RECORDING_STARTED_AT\""
            + " --ntn " + quote(configuration.cliPath)
            + " --parent-page " + quote(configuration.parentPageID)
            + " --window-minutes " + quote(String(configuration.windowMinutes))
        return LocalHook(name: "Migrated export", enabled: configuration.enabled,
                         event: .stopped, command: command, timeoutSeconds: 600)
    }
}

/// Keep raw editor text until Save, so failed parsing cannot silently retain
/// and save the previous numeric value.
enum LocalHookDraftValidation {
    static func timeout(_ text: String) throws -> TimeInterval {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, (1...3600).contains(value) else {
            throw LocalHookFailure("タイムアウトは1〜3600秒の数値で入力してください。")
        }
        return value
    }
}
