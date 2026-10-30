import Foundation

enum RecordingHookEvent: String, Codable, CaseIterable, Sendable {
    case started = "recording_started"
    case stopped = "recording_stopped"
}

/// User-configured integrations that run after the recorder has actually
/// started or completed transcription. Empty values intentionally mean "disabled".
struct RecordingHookConfiguration: Equatable, Sendable {
    var command: String = ""
    var webhookURL: String = ""

    var isEmpty: Bool {
        command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct RecordingHookContext: Sendable {
    let event: RecordingHookEvent
    let sessionDirectory: URL
    let occurredAt: Date
    let startedAt: Date

    private static let dateFormatter = ISO8601DateFormatter()

    var environment: [String: String] {
        [
            "SPLITVOX_HOOK_EVENT": event.rawValue,
            "SPLITVOX_SESSION_DIRECTORY": sessionDirectory.path,
            "SPLITVOX_RECORDING_STARTED_AT": Self.dateFormatter.string(from: startedAt),
            "SPLITVOX_HOOK_OCCURRED_AT": Self.dateFormatter.string(from: occurredAt)
        ]
    }

    var webhookBody: Data? {
        try? JSONSerialization.data(withJSONObject: [
            "event": event.rawValue,
            "sessionDirectory": sessionDirectory.path,
            "recordingStartedAt": Self.dateFormatter.string(from: startedAt),
            "occurredAt": Self.dateFormatter.string(from: occurredAt)
        ])
    }
}

/// One recording owns at most one completion, shared by live and file paths.
struct RecordingHookCompletion {
    private var startedAt: Date?
    mutating func start(at date: Date) { startedAt = date }
    mutating func finish(directory: URL, usableTranscript: Bool, occurredAt: Date = Date()) -> RecordingHookContext? {
        defer { startedAt = nil }
        guard usableTranscript, let startedAt else { return nil }
        return RecordingHookContext(event: .stopped, sessionDirectory: directory,
                                    occurredAt: occurredAt, startedAt: startedAt)
    }
}

/// Four command workers bound concurrency. Webhooks are dispatched separately,
/// without waiting for a worker or any preceding command.
final class RecordingHookDispatcher {
    static let shared = RecordingHookDispatcher()
    private let commands: OperationQueue
    private let postWebhook: (String, RecordingHookContext) -> Void
    private let record: (URL, String) -> Void

    init(postWebhook: @escaping (String, RecordingHookContext) -> Void = { RecordingHookDispatcher.post($0, context: $1) },
         record: @escaping (URL, String) -> Void = RecordingHookDispatcher.log) {
        commands = OperationQueue()
        commands.name = "splitvox.local-hooks"
        commands.qualityOfService = .utility
        commands.maxConcurrentOperationCount = 4
        self.postWebhook = postWebhook
        self.record = record
    }

    func fire(_ hooks: [LocalHook], webhookURL: String, context: RecordingHookContext) {
        for hook in hooks where hook.enabled && hook.event == context.event {
            let record = self.record
            commands.addOperation {
                let prefix = "hook \(hook.id.uuidString) \(context.event.rawValue) "
                record(context.sessionDirectory, prefix + "started")
                let result = LocalCommandRunner.run(hook, context: context)
                record(context.sessionDirectory, prefix + result.logStatus)
            }
        }
        if !webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            postWebhook(webhookURL, context)
        }
    }

    static func log(_ directory: URL, _ message: String) {
        let log = SessionLog(directory: directory)
        log.write(message)
        log.flush()
    }

    static func post(_ value: String, context: RecordingHookContext, session: URLSession = .shared,
                     record: @escaping (URL, String) -> Void = RecordingHookDispatcher.log) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              let body = context.webhookBody else {
            record(context.sessionDirectory, "webhook \(context.event.rawValue) invalid_url")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        session.dataTask(with: request) { _, response, error in
            // URLSession errors can include tokens in the URL. Status only.
            let status: String
            if error != nil { status = "failed" }
            else if let response = response as? HTTPURLResponse { status = "http=\(response.statusCode)" }
            else { status = "failed" }
            record(context.sessionDirectory, "webhook \(context.event.rawValue) \(status)")
        }.resume()
    }
}
