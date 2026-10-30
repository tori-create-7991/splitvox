import Foundation
import Testing
@testable import Splitvox

@Suite("Generic command-line boundary")
struct DiagnosticsCLITests {
    @Test("Unknown integration arguments fail before launching the app")
    func unknownOption() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = root.appendingPathComponent(".build/debug/Splitvox")
        process.arguments = ["--unsupported-integration-option"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let completed = done.wait(timeout: .now() + 3)
        if completed == .timedOut { process.terminate() }
        #expect(completed == .success)
        if completed == .success { #expect(process.terminationStatus == 2) }
    }
    @Test("Boundary checks fail closed for missing tools and search errors")
    func boundaryErrors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for searchError in [false, true] {
            if searchError {
                let fake = directory.appendingPathComponent("rg")
                try "#!/bin/sh\nexit 2\n".write(to: fake, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appendingPathComponent("scripts/check-notion-boundary.sh").path]
            process.environment = ["PATH": directory.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus != 0)
        }
    }

}
