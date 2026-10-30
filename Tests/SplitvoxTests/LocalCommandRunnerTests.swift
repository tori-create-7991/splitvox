import Foundation
import Testing
@testable import Splitvox

// Integration tests use synthetic shell commands and temporary files only.
@Suite("Local command execution")
struct LocalCommandRunnerTests {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func context(_ directory: URL, event: RecordingHookEvent = .stopped) -> RecordingHookContext {
        .init(event: event, sessionDirectory: directory, occurredAt: Date(timeIntervalSince1970: 1), startedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("Commands receive the unchanged event contract and EOF on stdin")
    func environment() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let hook = LocalHook(name: "Synthetic", command: "read value && exit 99; printf '%s\\n' \"$SPLITVOX_HOOK_EVENT\" \"$SPLITVOX_SESSION_DIRECTORY\" \"$SPLITVOX_RECORDING_STARTED_AT\" \"$SPLITVOX_HOOK_OCCURRED_AT\" > \"$SPLITVOX_SESSION_DIRECTORY/env\"")
        #expect(LocalCommandRunner.run(hook, context: context(directory)) == .exited(0))
        let lines = try String(contentsOf: directory.appendingPathComponent("env"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == ["recording_stopped", directory.path, "1970-01-01T00:00:00Z", "1970-01-01T00:00:01Z"])
    }

    @Test("Nonzero status is reported without stdout or stderr")
    func failure() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let result = LocalCommandRunner.run(.init(name: "SecretName", command: "echo transcript; echo token >&2; exit 7"), context: context(directory))
        #expect(result == .exited(7))
        #expect(result.logStatus == "exit=7")
    }

    @Test("Timeout kills shell descendants even when SIGTERM is ignored")
    func descendants() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let command = "trap '' TERM; (sleep 2; touch \"$SPLITVOX_SESSION_DIRECTORY/leaked\") & wait"
        #expect(LocalCommandRunner.run(.init(name: "Slow", command: command, timeoutSeconds: 1), context: context(directory)) == .timedOut)
        Thread.sleep(forTimeInterval: 1.3)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("leaked").path))
    }

    @Test("Configured exports may exceed the former fifteen second timeout")
    func longTimeout() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        #expect(LocalCommandRunner.run(.init(name: "Long", command: "sleep 16", timeoutSeconds: 25), context: context(directory)) == .exited(0))
    }

    @Test("Slow commands do not delay other commands or webhook dispatch")
    func concurrency() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let fast = DispatchSemaphore(value: 0), slow = DispatchSemaphore(value: 0), webhook = DispatchSemaphore(value: 0)
        let hooks = [LocalHook(name: "Slow", command: "sleep 2"), LocalHook(name: "Fast", command: "exit 0")]
        let dispatcher = RecordingHookDispatcher(postWebhook: { _, _ in webhook.signal() }, record: { _, message in
            if message.contains(hooks[1].id.uuidString) && message.contains("exit=0") { fast.signal() }
            if message.contains(hooks[0].id.uuidString) && message.contains("exit=0") { slow.signal() }
        })
        dispatcher.fire(hooks, webhookURL: "https://example.test/hook", context: context(directory))
        #expect(webhook.wait(timeout: .now() + 1) == .success)
        #expect(fast.wait(timeout: .now() + 1) == .success)
        #expect(slow.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(slow.wait(timeout: .now() + 4) == .success)
    }

    @Test("Only enabled matching entries run and generic logs stay bounded and source scoped")
    func routingAndLogging() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let finished = DispatchSemaphore(value: 0)
        let matching = LocalHook(name: "secret-name", command: "echo private-transcript; echo token >&2")
        let disabled = LocalHook(name: "Disabled", enabled: false, command: "touch \"$SPLITVOX_SESSION_DIRECTORY/disabled\"")
        let other = LocalHook(name: "Other", event: .started, command: "touch \"$SPLITVOX_SESSION_DIRECTORY/wrong\"")
        let dispatcher = RecordingHookDispatcher(record: { target, message in
            #expect(target == directory)
            #expect(message.utf8.count < 150)
            #expect(!message.contains("secret-name") && !message.contains("private-transcript") && !message.contains("token"))
            if message.contains("exit=0") { finished.signal() }
        })
        dispatcher.fire([disabled, other, matching], webhookURL: "", context: context(directory))
        #expect(finished.wait(timeout: .now() + 4) == .success)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("disabled").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("wrong").path))
    }
    @Test("Concurrent source log writers retain every generic result")
    func concurrentLogging() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let log = SessionLog(directory: directory)
            log.write("synthetic-result-\(index)")
            log.flush()
        }
        let text = try String(contentsOf: directory.appendingPathComponent("session.log"), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 100)
    }

    @Test("Webhook transport preserves JSON metadata and logs only status")
    func webhookTransport() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyntheticHookProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        RecordingHookDispatcher.post("https://example.test/hook?token=private", context: context(directory), session: session) { target, message in
            #expect(target == directory)
            #expect(message == "webhook recording_stopped http=403")
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 3) == .success)
    }

}


private final class SyntheticHookProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        #expect(json?["event"] == "recording_stopped")
        #expect(json?["recordingStartedAt"] == "1970-01-01T00:00:00Z")
        #expect(json?["occurredAt"] == "1970-01-01T00:00:01Z")
        #expect(json?["sessionDirectory"]?.hasPrefix(FileManager.default.temporaryDirectory.path) == true)
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
