import Foundation
import CryptoKit
import Testing
@testable import SplitvoxNotion

// Integration tests: independent executable, temporary fixtures, no app/API.
@Suite("Standalone CLI integration")
struct CLIIntegrationTests {
    var binary: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/splitvox-notion")
    }
    func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func script(_ body: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("fake-ntn")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    func invoke(_ args: [String]) throws -> Data {
        try NotionCLI.run(executable: binary.path, arguments: args, timeout: 5)
    }
    @Test("Help needs neither the app nor ntn")
    func help() throws {
        #expect(String(decoding: try invoke(["--help"]), as: UTF8.self).contains("Normal export uses only arguments"))
    }
    @Test("A legacy completed journal returns without any API request")
    func oldJournal() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = "Synthetic legacy journal fixture\n"
        try transcript.write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let digest = SHA256.hash(data: Data(transcript.utf8)).map { String(format: "%02x", $0) }.joined()
        let note = "11111111-1111-4111-8111-111111111111"
        let journal: [String: Any] = ["sessionID": "legacy-fixture", "startedAt": 0, "digest": digest,
                                     "phase": "complete", "noteID": note, "completed": true]
        try JSONSerialization.data(withJSONObject: journal).write(to: directory.appendingPathComponent(".notion-sync.json"))
        let fake = try script("touch \"\(directory.path)/unexpected-api\"; exit 99", in: directory)
        let output = try invoke(["--notion-sync", directory.path, "--started-at", "2026-10-30T00:00:00Z", "--ntn", fake.path, "--write"])
        #expect(String(decoding: output, as: UTF8.self).contains("送信済み"))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("unexpected-api").path))
    }
    @Test("Host timeout contains the standalone exporter and fake API descendants")
    func hostGroupTimeout() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        try "Synthetic transcript".write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let fake = try script("""
        trap '' HUP TERM
        touch "\(directory.path)/started"
        printf '%s' "$_SPLITVOX_LOCAL_HOOK_GROUP" > "\(directory.path)/outer"
        /bin/ps -o pgid= -p $$ > "\(directory.path)/inner"
        (sleep 2; touch "\(directory.path)/leaked") & wait
        """, in: directory)
        // A host-owned group and marker are the generic optional protocol; no
        // app source or app executable participates in this integration test.
        let command = "export _SPLITVOX_LOCAL_HOOK_GROUP=$$; exec " + HookMigration.quote(binary.path)
            + " --notion-sync " + HookMigration.quote(directory.path)
            + " --started-at 2026-10-30T00:00:00Z --ntn " + HookMigration.quote(fake.path) + " --write"
        do {
            _ = try NotionCLI.run(executable: "/bin/zsh", arguments: ["-lc", command], timeout: 1)
            Issue.record("Expected host timeout")
        } catch { #expect(error.localizedDescription.contains("タイムアウト")) }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("started").path))
        let outer = try String(contentsOf: directory.appendingPathComponent("outer"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let inner = try String(contentsOf: directory.appendingPathComponent("inner"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!outer.isEmpty && outer == inner)
        Thread.sleep(forTimeInterval: 1.3)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("leaked").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".notion-sync.lock").path))
    }
    @Test("Explicit migration dry-run leaves preferences intact; apply backs up and remains idempotent")
    func migrationCommand() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let domain = "SplitvoxNotionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let legacy = LegacyNotionPreferences(enabled: false, cliPath: "/tmp/fake", parentPageID: "", windowMinutes: 10)
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: "notionConfiguration"); defaults.synchronize()
        let args = ["--migrate-local-hooks", "--domain", domain, "--new-executable", binary.path, "--backup-directory", directory.path]
        let dry = try JSONSerialization.jsonObject(with: invoke(args)) as! [String: Any]
        #expect(dry["applied"] as? Bool == false)
        #expect(defaults.persistentDomain(forName: domain)?["localHooksConfiguration"] == nil)
        let applied = try JSONSerialization.jsonObject(with: invoke(args + ["--write"])) as! [String: Any]
        #expect(applied["applied"] as? Bool == true)
        let backup = try #require(applied["backupPath"] as? String)
        let restored = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: backup)), format: nil) as! [String: Any]
        #expect(restored["notionConfiguration"] as? Data == data)
        defaults.synchronize()
        #expect(defaults.persistentDomain(forName: domain)?["notionConfiguration"] as? Data == data)
        let repeated = try JSONSerialization.jsonObject(with: invoke(args + ["--write"])) as! [String: Any]
        #expect(repeated["applied"] as? Bool == false)
        #expect(repeated["changedHooks"] as? Int == 0)
    }
}
