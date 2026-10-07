import Foundation

/// Runs a child process with an explicit, minimal environment.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    /// Environment passed to every child: enough for tools to work, nothing
    /// that could make them reach the network on our behalf. In particular no
    /// `*_API_KEY` variables — graphify would use them to call an LLM.
    public static func cleanEnvironment(extra: [String: String] = [:]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PYTHONIOENCODING": "utf-8",
            "PYTHONUNBUFFERED": "1",
            "NO_COLOR": "1",
        ]
        for key in ["HOME", "TMPDIR", "USER", "LOGNAME"] {
            if let v = inherited[key] { env[key] = v }
        }
        // Any git these children run (ours, or graphify's) must never execute
        // commands from a repository's own config: `core.fsmonitor`,
        // hooks, … in a downloaded repo would otherwise run on open.
        for (i, (k, v)) in gitSafety.enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = k
            env["GIT_CONFIG_VALUE_\(i)"] = v
        }
        env["GIT_CONFIG_COUNT"] = "\(gitSafety.count)"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env.merge(extra) { _, new in new }
        return env
    }

    /// `git -c` settings applied through the environment (see cleanEnvironment).
    public static let gitSafety: [(String, String)] = [
        ("core.fsmonitor", "false"),
        ("core.hooksPath", "/dev/null"),
        ("core.sshCommand", "false"),
        ("protocol.ext.allow", "never"),
        ("diff.external", ""),
    ]

    /// Adds more `GIT_CONFIG_*` pairs after the safety ones.
    public static func appendingGitConfig(_ env: [String: String], _ pairs: [(String, String)]) -> [String: String] {
        var env = env
        var n = Int(env["GIT_CONFIG_COUNT"] ?? "0") ?? 0
        for (k, v) in pairs {
            env["GIT_CONFIG_KEY_\(n)"] = k
            env["GIT_CONFIG_VALUE_\(n)"] = v
            n += 1
        }
        env["GIT_CONFIG_COUNT"] = "\(n)"
        return env
    }

    /// Runs to completion, collecting output. Cancelling the calling task
    /// terminates the process.
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector(onLine: onLine)
        outPipe.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, stream: .out) }
        errPipe.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, stream: .err) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(outPipe.fileHandleForReading.readDataToEndOfFile(), stream: .out)
                    collector.append(errPipe.fileHandleForReading.readDataToEndOfFile(), stream: .err)
                    collector.flush()
                    let (o, e) = collector.text()
                    cont.resume(returning: Result(status: p.terminationStatus, stdout: o, stderr: e))
                }
                do {
                    try process.run()
                    // Cancelled between task start and launch: onCancel ran
                    // too early to stop anything.
                    if Task.isCancelled { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Thread-safe stdout/stderr accumulator that also splits lines for live
/// progress. graphify uses `\r` for in-place progress, so both separators count.
private final class OutputCollector: @unchecked Sendable {
    enum Stream { case out, err }
    private let lock = NSLock()
    private var out = Data(), err = Data()
    /// Partial line per stream, so stdout and stderr never splice together.
    private var pending: [Stream: String] = [.out: "", .err: ""]
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data, stream: Stream) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        if stream == .out { out.append(data) } else { err.append(data) }
        if onLine != nil {
            var buffer = pending[stream, default: ""] + String(decoding: data, as: UTF8.self)
            while let r = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(buffer[..<r])
                buffer = String(buffer[buffer.index(after: r)...])
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
            }
            pending[stream] = buffer
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func flush() {
        lock.lock()
        let rest = [pending[.out, default: ""], pending[.err, default: ""]]
        pending = [.out: "", .err: ""]
        lock.unlock()
        for r in rest where !r.trimmingCharacters(in: .whitespaces).isEmpty { onLine?(r) }
    }

    func text() -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}
