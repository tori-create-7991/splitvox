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
