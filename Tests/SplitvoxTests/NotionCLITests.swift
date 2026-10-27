import Foundation
import Testing
@testable import Splitvox

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
        }
    }
    @Test("A hung child is terminated")
    func timeout() {
        #expect(throws: (any Error).self) {
            try NotionCLI.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1)
        }
    }
}
