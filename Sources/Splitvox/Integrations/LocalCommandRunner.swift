import Foundation
import Darwin

/// No arbitrary output is captured: commands own their private diagnostics.
/// A separate process group bounds the lifetime of shell wrappers and children.
enum LocalCommandRunner {
    enum Result: Equatable {
        case exited(Int32), timedOut, launchFailed
        var logStatus: String {
            switch self {
            case .exited(let code): return "exit=\(code)"
            case .timedOut: return "timeout"
            case .launchFailed: return "launch_failed"
            }
        }
    }

    static func run(_ hook: LocalHook, context: RecordingHookContext) -> Result {
        guard hook.timeoutSeconds.isFinite, (1...3600).contains(hook.timeoutSeconds) else { return .launchFailed }
        let environment = ProcessInfo.processInfo.environment.merging(context.environment) { _, value in value }
        // A constant shell prefix identifies the owned group to our headless
        // compatibility CLI. Never interpolate session/user data into it.
        let arguments: [String] = ["/bin/zsh", "-lc", "export _SPLITVOX_LOCAL_HOOK_GROUP=$$; " + hook.command]
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let null = Darwin.open("/dev/null", O_RDWR)
        guard null >= 0 else { return .launchFailed }
        defer { close(null) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) == 0 else { return .launchFailed }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { av in
            envp.withUnsafeMutableBufferPointer { ev in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, av.baseAddress!, ev.baseAddress!)
            }
        }
        guard spawned == 0 else { return .launchFailed }
        // Kill any remaining background descendants on every exit path.
        defer { kill(-pid, SIGKILL) }
        let deadline = ProcessInfo.processInfo.systemUptime + hook.timeoutSeconds
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                // Darwin wait status: low seven bits are the signal, high byte
                // is the exit code. Keep failures distinct from success.
                let signal = status & 0x7f
                return .exited(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
            }
            if result < 0 && errno != EINTR { return .launchFailed }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                kill(-pid, SIGTERM)
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR { }
                return .timedOut
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
