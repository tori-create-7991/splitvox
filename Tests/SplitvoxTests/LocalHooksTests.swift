import Foundation
import Testing
@testable import Splitvox

// Unit tests: isolated defaults only; never read the user's saved hooks.
@Suite("Local hook settings")
struct LocalHooksTests {
    private func isolated() -> UserDefaults {
        UserDefaults(suiteName: "SplitvoxTests.hooks." + UUID().uuidString)!
    }

    @Test("Entries round-trip independently and explicit empty never resurrects legacy hooks")
    func roundTrip() throws {
        let defaults = isolated()
        let store = PreferenceStore(defaults: defaults)
        defaults.set("echo old", forKey: "recordingStartedCommand")
        let hooks = [LocalHook(name: "One", event: .started, command: "echo first"),
                     LocalHook(name: "Two", enabled: false, event: .stopped, command: "echo second", timeoutSeconds: 600)]
        try store.saveLocalHooks(hooks)
        #expect(try store.loadLocalHooks() == hooks)
        try store.saveLocalHooks([])
        #expect(try store.loadLocalHooks().isEmpty)
        #expect(defaults.string(forKey: "recordingStartedCommand") == "echo old")
    }

    @Test("Both legacy commands migrate once and URLs stay unchanged")
    func migrateCommands() throws {
        let defaults = isolated()
        let store = PreferenceStore(defaults: defaults)
        store.setRecordingHook(.init(command: "echo start", webhookURL: "https://example.test/start"), for: .started)
        store.setRecordingHook(.init(command: "echo end", webhookURL: "https://example.test/end"), for: .stopped)
        let first = try store.loadLocalHooks()
        #expect(first.map(\.event) == [.started, .stopped])
        #expect(first.map(\.command) == ["echo start", "echo end"])
        #expect(first.allSatisfy { $0.enabled && $0.timeoutSeconds == 15 })
        #expect(try store.loadLocalHooks() == first)
        #expect(store.recordingHook(for: .started).webhookURL == "https://example.test/start")
        #expect(store.recordingHook(for: .stopped).webhookURL == "https://example.test/end")
        try store.saveLocalHooks(Array(first.dropFirst()))
        #expect(try store.loadLocalHooks() == Array(first.dropFirst()))
    }

    @Test("Legacy Notion preserves enablement and explicit parameters as shell literals", arguments: [true, false])
    func migrateNotion(enabled: Bool) throws {
        let defaults = isolated()
        let store = PreferenceStore(defaults: defaults)
        store.notionConfiguration = .init(enabled: enabled, cliPath: "/tmp/my cli'$(touch NEVER)", parentPageID: "parent';&", windowMinutes: 37)
        let hooks = try store.loadLocalHooks(executablePath: "/tmp/My App'$(touch NEVER)/Splitvox")
        #expect(hooks.count == 1)
        let hook = try #require(hooks.first)
        #expect(hook.enabled == enabled)
        #expect(hook.event == .stopped)
        #expect(hook.timeoutSeconds == 600)
        #expect(hook.command.contains("--window-minutes '37.0'"))
        // Execute only printf of the generated argv; never launch an exporter.
        let output = try NotionCLI.run(executable: "/bin/sh", arguments: ["-c", "printf '%s\\n' " + hook.command], timeout: 2, environment: ["SPLITVOX_SESSION_DIRECTORY": "/tmp/session'$(noop)", "SPLITVOX_RECORDING_STARTED_AT": "2026-10-30T01:00:00Z"])
        let argv = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(argv == ["/tmp/My App'$(touch NEVER)/Splitvox", "--notion-sync", "/tmp/session'$(noop)", "--write", "--started-at", "2026-10-30T01:00:00Z", "--ntn", "/tmp/my cli'$(touch NEVER)", "--parent-page", "parent';&", "--window-minutes", "37.0"])
        #expect(try store.loadLocalHooks() == hooks)
        #expect(store.notionConfiguration.enabled == enabled)
    }

    @Test("Absent preferences migrate to a durable empty list")
    func empty() throws {
        let defaults = isolated()
        let store = PreferenceStore(defaults: defaults)
        #expect(try store.loadLocalHooks().isEmpty)
        defaults.set("echo later", forKey: "recordingStartedCommand")
        #expect(try store.loadLocalHooks().isEmpty)
    }

    @Test("Unknown or malformed settings fail without legacy fallback or overwrite", arguments: ["{}", "{\"version\":999,\"hooks\":[]}", "bad"])
    func malformed(json: String) throws {
        let defaults = isolated()
        defaults.set(Data(json.utf8), forKey: "localHooksConfiguration")
        defaults.set("echo must-not-run", forKey: "recordingStartedCommand")
        let store = PreferenceStore(defaults: defaults)
        #expect(throws: (any Error).self) { try store.loadLocalHooks() }
        #expect(defaults.data(forKey: "localHooksConfiguration") == Data(json.utf8))
    }

    @Test("Timeout, empty enabled commands, and duplicate identities are rejected")
    func validation() throws {
        let store = PreferenceStore(defaults: isolated())
        for timeout in [0, 3601, Double.nan, Double.infinity] {
            #expect(throws: (any Error).self) { try store.saveLocalHooks([LocalHook(name: "Test", command: "true", timeoutSeconds: timeout)]) }
        }
        #expect(throws: (any Error).self) { try store.saveLocalHooks([LocalHook(name: "Test", command: " ")]) }
        let hook = LocalHook(name: "Test", command: "true")
        #expect(throws: (any Error).self) { try store.saveLocalHooks([hook, hook]) }
        try store.saveLocalHooks([LocalHook(name: "Draft", enabled: false)])
        #expect(try store.loadLocalHooks().count == 1)
    }
    @Test("Completion dispatch requires a saved usable transcript and is consumed once")
    func completion() {
        let directory = URL(fileURLWithPath: "/tmp/synthetic-recording")
        let date = Date(timeIntervalSince1970: 1)
        var completion = RecordingHookCompletion()
        #expect(completion.finish(directory: directory, usableTranscript: true) == nil)
        completion.start(at: date)
        #expect(completion.finish(directory: directory, usableTranscript: false) == nil)
        #expect(completion.finish(directory: directory, usableTranscript: true) == nil)
        // Both successful transcription paths consume this same gate.
        for _ in 0..<2 {
            completion.start(at: date)
            let context = completion.finish(directory: directory, usableTranscript: true)
            #expect(context?.startedAt == date)
            #expect(context?.sessionDirectory == directory)
            #expect(context?.event == .stopped)
            #expect(completion.finish(directory: directory, usableTranscript: true) == nil)
        }
    }

    @Test("Timeout editor rejects empty and unparseable drafts rather than saving stale values")
    func timeoutDrafts() throws {
        for value in ["", " ", "abc", "NaN", "inf", "0", "3601"] {
            #expect(throws: (any Error).self) { try LocalHookDraftValidation.timeout(value) }
        }
        #expect(try LocalHookDraftValidation.timeout("600") == 600)
        #expect(try LocalHookDraftValidation.timeout(" 15 ") == 15)
    }

}
