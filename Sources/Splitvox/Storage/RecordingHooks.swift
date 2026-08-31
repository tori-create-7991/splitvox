import Foundation

enum RecordingHookEvent: String, Sendable {
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

/// Runs user-configured commands and webhooks away from the recording actor.
/// An integration must never delay or prevent audio capture.
enum RecordingHookRunner {
    private static let queue = DispatchQueue(
        label: "io.github.tori-create-7991.splitvox.recording-hooks",
        qos: .utility
    )

    static func fire(_ configuration: RecordingHookConfiguration, context: RecordingHookContext) {
        guard !configuration.isEmpty else { return }

        queue.async {
            runCommand(configuration.command, context: context)
            postWebhook(configuration.webhookURL, context: context)
        }
    }

    private static func runCommand(_ command: String, context: RecordingHookContext) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment.merging(context.environment) { _, hookValue in
            hookValue
        }

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
            if completion.wait(timeout: .now() + 15) == .timedOut {
                process.terminate()
                NSLog("[Splitvox] %@ hook command timed out", context.event.rawValue)
            } else if process.terminationStatus != 0 {
                NSLog("[Splitvox] %@ hook command exited with status %d", context.event.rawValue,
                      process.terminationStatus)
            }
        } catch {
            NSLog("[Splitvox] %@ hook command failed: %@", context.event.rawValue,
                  error.localizedDescription)
        }
    }

    private static func postWebhook(_ value: String, context: RecordingHookContext) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard let url = URL(string: value), let body = context.webhookBody else {
            NSLog("[Splitvox] %@ hook webhook URL is invalid", context.event.rawValue)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                NSLog("[Splitvox] %@ hook webhook failed: %@", context.event.rawValue,
                      error.localizedDescription)
            } else if let response = response as? HTTPURLResponse,
                      !(200..<300).contains(response.statusCode) {
                NSLog("[Splitvox] %@ hook webhook returned HTTP %ld", context.event.rawValue,
                      response.statusCode)
            }
        }.resume()
    }
}
