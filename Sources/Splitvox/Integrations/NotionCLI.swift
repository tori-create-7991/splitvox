import Foundation
import Darwin

struct NotionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Requests never inherit an open stdin or an ambient integration token.
/// Private files also avoid pipe-buffer deadlocks on large responses.
struct NotionCLI {
    let executable: String

    init(path: String = "") throws {
        if path.isEmpty {
            let data = try Self.run(executable: "/bin/zsh", arguments: ["-lc", "command -v ntn"], timeout: 10)
            executable = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } else { executable = NSString(string: path).expandingTildeInPath }
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw NotionFailure("ntnが見つかりません。設定でCLIの絶対パスを指定してください。")
        }
    }

    func call(_ method: String, _ endpoint: String, _ body: [String: Any]? = nil) throws -> [String: Any] {
        var arguments = ["api", endpoint, "-X", method, "--notion-version", "2026-03-11"]
        let request = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: request, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: request) }
        if let body {
            let file = request.appendingPathComponent("request.json")
            try JSONSerialization.data(withJSONObject: body).write(to: file)
            arguments += ["-d", "@" + file.path]
        }
        let data = try Self.run(executable: executable, arguments: arguments, timeout: 120)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["object"] as? String != "error" else {
            throw NotionFailure("Notionがリクエストを受け付けませんでした。ntn doctorで認証と権限を確認してください。")
        }
        return result
    }

    static func run(executable: String, arguments: [String], timeout: TimeInterval,
                    environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("splitvox-ntn-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("stdout")
        let errors = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        let err = try FileHandle(forWritingTo: errors)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = environment
        env.removeValue(forKey: "NOTION_API_TOKEN")
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
            throw NotionFailure("ntnがタイムアウトしました。送信済みの可能性があるため、状態を照合してから再試行してください。")
        }
        guard process.terminationStatus == 0 else {
            throw NotionFailure("ntnが終了コード\(process.terminationStatus)で失敗しました。ターミナルでntn doctorを確認してください。")
        }
        return try Data(contentsOf: output)
    }
}
