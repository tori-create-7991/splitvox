import Foundation
import Darwin

/// Standalone logger: no dependency on the host app or audio enumeration.
enum ExportLog {
    static func write(_ message: String, directory: URL) {
        let descriptor = Darwin.open(directory.appendingPathComponent("session.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { fputs("Notion: log open failed\n", stderr); return }
        defer { close(descriptor) }
        let data = Data((message + "\n").utf8)
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if written != data.count { fputs("Notion: log append failed\n", stderr) }
    }
}
