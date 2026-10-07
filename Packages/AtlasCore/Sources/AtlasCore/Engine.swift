import Foundation

/// Drives graphify to (re)build a project's graph.
///
/// Always code-only, always with a scrubbed environment (no API keys), and
/// always writing into Atlas's own data folder — never into the project.
public struct Engine: Sendable {
    public let executable: URL
    public let logDirectory: URL?

    public init(executable: URL, logDirectory: URL? = nil) {
        self.executable = executable
        self.logDirectory = logDirectory
    }

    public enum Phase: Sendable, Equatable {
        case scanning
        /// AST extraction progress (files done / total).
        case extracting(done: Int, total: Int)
        case clustering
        case finished
    }

    public enum EngineError: Error, LocalizedError {
        case notFound
        case failed(step: String, status: Int32, tail: String)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return String(localized: "Analiz motoru bulunamadı.")
            case .failed(let step, let status, let tail):
                return String(localized: "Analiz motoru hata verdi (\(step), kod \(status)).\n\(tail)")
            }
        }
    }

    /// Finds an engine: the one bundled in the app first, then a user
    /// install (`uv tool install graphifyy`).
    public static func locate(bundle: Bundle = .main) -> Engine? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = bundle.resourceURL {
            candidates.append(res.appendingPathComponent("Engine/bin/graphify"))
        }
        let home = fm.homeDirectoryForCurrentUser
        candidates += [
            home.appendingPathComponent(".local/bin/graphify"),
            URL(fileURLWithPath: "/opt/homebrew/bin/graphify"),
            URL(fileURLWithPath: "/usr/local/bin/graphify"),
        ]
        guard let exe = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else { return nil }
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Atlas", isDirectory: true)
        return Engine(executable: exe, logDirectory: logs)
    }

    /// Builds or incrementally updates the graph for `root` into
    /// `output/graphify-out/`. graphify detects a previous run in the output
    /// folder and only re-extracts changed files.
    public func index(
        root: URL,
        output: URL,
        logName: String,
        progress: @escaping @Sendable (Phase) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let log = LogFile(directory: logDirectory, name: logName)
        log.write("== \(Date()) index \(root.path)")
        progress(.scanning)

        let env = ProcessRunner.cleanEnvironment(extra: [
            // Belt and braces: graphify's opt-in query log stays off.
            "GRAPHIFY_QUERY_LOG": "",
        ])

        let extract = try await ProcessRunner.run(
            executable: executable,
            arguments: ["extract", root.path, "--code-only", "--out", output.path],
            environment: env,
            currentDirectory: root
        ) { line in
            log.write(line)
            if let p = Self.parseProgress(line) { progress(.extracting(done: p.0, total: p.1)) }
        }
        try Task.checkCancellation()
        guard extract.status == 0 else {
            throw EngineError.failed(step: "extract", status: extract.status, tail: Self.tail(extract))
        }

        progress(.clustering)
        let cluster = try await ProcessRunner.run(
            executable: executable,
            arguments: ["cluster-only", output.path, "--no-viz"],
            environment: env,
            currentDirectory: output
        ) { line in log.write(line) }
        try Task.checkCancellation()
        guard cluster.status == 0 else {
            throw EngineError.failed(step: "cluster", status: cluster.status, tail: Self.tail(cluster))
        }
        log.write("== done")
        progress(.finished)
    }

    /// `  AST extraction: 100/562 uncached files (17%) [10 workers]` → (100, 562)
    static func parseProgress(_ line: String) -> (Int, Int)? {
        guard let r = line.range(of: "AST extraction: ") else { return nil }
        let rest = line[r.upperBound...]
        let parts = rest.prefix { $0.isNumber || $0 == "/" }.split(separator: "/")
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > 0 else { return nil }
        return (a, b)
    }

    private static func tail(_ r: ProcessRunner.Result) -> String {
        let lines = (r.stderr + "\n" + r.stdout).split(separator: "\n").suffix(6)
        return lines.joined(separator: "\n")
    }
}

/// Append-only log in `~/Library/Logs/Atlas/<name>.log`, rotated at 2 MB.
final class LogFile: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()

    init(directory: URL?, name: String) {
        guard let directory else { url = nil; return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).log")
        if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 2_000_000 {
            let old = directory.appendingPathComponent("\(name).1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: file, to: old)
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        url = file
    }

    func write(_ line: String) {
        guard let url, let data = (line + "\n").data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }
}
