import Foundation
import Darwin

struct NotionFailure: LocalizedError {
    let message: String
    let definiteRejection: Bool
    var errorDescription: String? { message }
    init(_ message: String, definiteRejection: Bool = false) { self.message = message; self.definiteRejection = definiteRejection }
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
            throw NotionFailure("ntnが見つかりません。--ntn <絶対パス>または外部スクリプトでCLIを指定してください。")
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
        var env = environment
        env.removeValue(forKey: "NOTION_API_TOKEN")
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw NotionFailure("ntn実行の準備に失敗しました。") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw NotionFailure("ntn入出力の準備に失敗しました。") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let input = Darwin.open("/dev/null", O_RDONLY)
        guard input >= 0 else { throw NotionFailure("標準入力を閉じられませんでした。") }
        defer { close(input) }
        // An exporter launched by a local hook must keep API requests inside
        // that hook's lifetime. A numeric, verified marker cannot target an
        // unrelated process group. Standalone CLI retains its own group.
        let marker = environment["_SPLITVOX_LOCAL_HOOK_GROUP"].flatMap(Int32.init)
        let managedGroup = marker.flatMap { $0 > 1 && $0 == getpgrp() ? $0 : nil }
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | (managedGroup == nil ? POSIX_SPAWN_SETPGROUP : 0)
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0,
              (managedGroup != nil || posix_spawnattr_setpgroup(&attributes, 0) == 0),
              posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, out.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, err.fileDescriptor, STDERR_FILENO) == 0 else {
            throw NotionFailure("ntn実行グループの準備に失敗しました。")
        }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { av in
            envp.withUnsafeMutableBufferPointer { ev in
                posix_spawn(&pid, executable, &actions, &attributes, av.baseAddress!, ev.baseAddress!)
            }
        }
        guard spawned == 0 else { throw NotionFailure("ntnを起動できませんでした（\(spawned)）。CLIパスを確認してください。", definiteRejection: true) }
        // Only standalone calls own the child group. The hook runner owns
        // managed groups and cleans all remaining descendants on outer exit.
        defer { if managedGroup == nil { kill(-pid, SIGKILL) } }
        var status: Int32 = 0
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result < 0 && errno != EINTR { throw NotionFailure("ntnの終了を確認できませんでした。") }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                if let managedGroup {
                    // Hard stop the verified outer group, including this
                    // exporter. Its journal/lock stay for explicit recovery.
                    kill(-managedGroup, SIGKILL)
                }
                kill(-pid, SIGTERM)
                // Child wrappers may inherit a blocked/ignored SIGTERM.
                // Kill the owned group before releasing the session lock.
                kill(-pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
                throw NotionFailure("ntnがタイムアウトしました。送信済みの可能性があるため、状態を照合してから再試行してください。")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard status == 0 else {
            let diagnostic = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            // Match the CLI's structured status prefix only; never expose its
            // response text, which can contain URLs or user content.
            let rejected = diagnostic.range(of: #"^error: Public API request failed \((400|401|403|404|413|422|429)\b"#, options: .regularExpression) != nil
            throw NotionFailure("ntnが失敗しました。ntn doctorで認証と権限、親ページの設定を確認してください。", definiteRejection: rejected)
        }
        return try Data(contentsOf: output)
    }
}
