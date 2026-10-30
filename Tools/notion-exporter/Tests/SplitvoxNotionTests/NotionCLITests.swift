import Foundation
import Testing
@testable import SplitvoxNotion

@Suite("Notion CLI process")
struct NotionCLITests {
    @Test("Process stdin is closed and ambient API token is removed")
    func stdinAndEnvironment() throws {
        let data = try NotionCLI.run(executable: "/bin/sh", arguments: ["-c", "read value || true; printf '%s' \"${NOTION_API_TOKEN-unset}\""], timeout: 2, environment: ["NOTION_API_TOKEN": "must-not-leak"])
        #expect(String(data: data, encoding: .utf8) == "unset")
    }
    @Test("Nonzero exit is an error without leaking stderr")
    func failure() {
        do {
            _ = try NotionCLI.run(executable: "/bin/sh", arguments: ["-c", "echo secret >&2; exit 7"], timeout: 2)
            Issue.record("Expected failure")
        } catch {
            #expect(!error.localizedDescription.contains("secret"))
            #expect(error.localizedDescription.contains("ntnが失敗"))
        }
    }
    @Test("A hung child is terminated")
    func timeout() {
        do {
            _ = try NotionCLI.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1)
            Issue.record("Expected timeout")
        } catch { #expect(error.localizedDescription.contains("タイムアウト")) }
    }
    @Test("A definite API rejection is typed without exposing response text")
    func rejection() {
        do {
            _ = try NotionCLI.run(executable: "/bin/sh", arguments: ["-c", "echo 'error: Public API request failed (403 Forbidden restricted_resource): private' >&2; exit 1"], timeout: 2)
            Issue.record("Expected rejection")
        } catch {
            #expect((error as? NotionFailure)?.definiteRejection == true)
            #expect(!error.localizedDescription.contains("private"))
        }
    }
    @Test("Timeout stops descendants of a CLI wrapper")
    func descendants() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        do {
            _ = try NotionCLI.run(executable: "/bin/sh", arguments: ["-c", "(sleep 1; touch \"$1\") & wait", "wrapper", marker.path], timeout: 0.1)
            Issue.record("Expected timeout")
        } catch { #expect(error.localizedDescription.contains("タイムアウト")) }
        Thread.sleep(forTimeInterval: 1.2)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    // Unit test: validate arguments without discovering ntn or reading defaults.
    @Test("Window override is explicit, finite and within the supported range")
    func windowArguments() throws {
        let legacy = NotionConfiguration(cliPath: "/tmp/fake ntn", parentPageID: "parent", windowMinutes: 37)
        let config = try NotionCommand.configuration(["--window-minutes", "23", "--ntn", "/tmp/other", "--parent-page", ""], base: legacy)
        #expect(config.windowMinutes == 23)
        #expect(config.cliPath == "/tmp/other")
        #expect(config.parentPageID.isEmpty)
        #expect(try NotionCommand.configuration([], base: legacy) == legacy)
        for invalid in ["0", "121", "nan", "inf", "abc", "--write"] {
            #expect(throws: (any Error).self) { try NotionCommand.configuration(["--window-minutes", invalid], base: legacy) }
        }
        #expect(throws: (any Error).self) { try NotionCommand.configuration(["--window-minutes"], base: legacy) }
    }

}

// Unit: destination arguments fail before any API or preferences access.
@Suite("Notion database destination arguments")
struct NotionDestinationArgumentTests {
    @Test("Database destination flags validate UUID, property and exclusive parent")
    func invalidDestinationArguments() {
        let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        for args in [
            ["--data-source", "not-a-uuid"],
            ["--data-source", ""],
            ["--data-source"],
            ["--data-source", id, "--data-source", id],
            ["--date-property", "Start Date"],
            ["--data-source", id, "--date-property", ""],
            ["--data-source", id, "--date-property"],
            ["--data-source", id, "--parent-page", id]
        ] {
            #expect(throws: (any Error).self) { try NotionCommand.configuration(args) }
        }
    }
}

// Unit: destination normalization is stable for journal bindings.
@Test("Database destination accepts an empty legacy parent and preserves date column")
func validDatabaseDestinationArguments() throws {
    let config = try NotionCommand.configuration(["--data-source", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "--parent-page", "", "--date-property", "Recorded at"])
    #expect(config.dataSourceID == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    #expect(config.dateProperty == "Recorded at")
}

// Unit: a mistyped destination must never enter workspace export mode.
@Test("Unknown options and stray argument values are rejected")
func unknownExportArguments() {
    for args in [["--data-sorce", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"], ["--write", "unexpected"], ["--note"], ["--notion-status", "--notion-status"]] {
        #expect(throws: (any Error).self) { try NotionCommand.configuration(args) }
    }
}
