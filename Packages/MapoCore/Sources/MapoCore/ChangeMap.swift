import Foundation

/// "What changed since X?" in map terms: a git diff turned into the files and
/// symbols it touches. Deterministic, read-only, no network.
///
/// Symbols only carry a start line, so a changed line belongs to the nearest
/// symbol declared at or above it in the same file; lines above the first
/// symbol are the file's header (imports, constants).
public enum ChangeMap {
    /// New-side line ranges per repo-relative path, from `git diff --unified=0`.
    public struct Diff: Sendable, Equatable {
        public var hunks: [String: [ClosedRange<Int>]] = [:]
        public var added: Set<String> = []
        public var deleted: Set<String> = []
    }

    public struct FileChange: Sendable {
        public let path: String
        /// Position of the file node, nil when the file is not in the map.
        public let file: Int?
        public let symbols: [Int]
        public let header: Bool
        public let added: Bool
        public let deleted: Bool
    }

    // MARK: - Parsing

    /// Parses `git diff --unified=0 --no-renames` output. Paths come from the
    /// `+++ b/` (or `--- a/` for deletions) lines.
    public static func parse(_ text: String) -> Diff {
        var d = Diff()
        var oldPath: String?
        var current: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                oldPath = nil; current = nil
            } else if line.hasPrefix("--- ") {
                oldPath = path(line.dropFirst(4), prefix: "a/")
            } else if line.hasPrefix("+++ ") {
                if let p = path(line.dropFirst(4), prefix: "b/") {
                    current = p
                    if oldPath == nil { d.added.insert(p) }
                } else if let old = oldPath {
                    current = nil
                    d.deleted.insert(old)
                }
            } else if line.hasPrefix("@@"), let file = current, let range = newRange(line) {
                d.hunks[file, default: []].append(range)
            }
        }
        return d
    }

    /// `a/x.ts` → `x.ts`; `/dev/null` → nil; C-quoted paths are unquoted.
    static func path(_ s: Substring, prefix: String) -> String? {
        var s = String(s)
        if let tab = s.firstIndex(of: "\t") { s = String(s[..<tab]) }
        if s == "/dev/null" { return nil }
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 { s = unquote(String(s.dropFirst().dropLast())) }
        return s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
    }

    /// git's C-style quoting: `\"`, `\\`, `\t`, `\n` and octal UTF-8 bytes.
    static func unquote(_ s: String) -> String {
        var bytes: [UInt8] = []
        var it = Array(s.utf8)[...]
        while let c = it.popFirst() {
            guard c == UInt8(ascii: "\\"), let n = it.popFirst() else { bytes.append(c); continue }
            switch n {
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var v = Int(n - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let d = it.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(d) else { break }
                    v = v * 8 + Int(d - UInt8(ascii: "0")); it = it.dropFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: v))
            default: bytes.append(n)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `@@ -a,b +c,d @@` → c…c+d-1. A pure deletion (d = 0) marks line c,
    /// the line it was removed after.
    static func newRange(_ header: String) -> ClosedRange<Int>? {
        guard let plus = header.firstIndex(of: "+") else { return nil }
        let spec = header[header.index(after: plus)...].prefix { $0 != " " }
        let parts = spec.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(parts.first ?? ""), start >= 0 else { return nil }
        let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        let first = max(1, start)
        return first...max(first, start + count - 1)
    }

    // MARK: - Mapping onto the graph

    public static func changes(in graph: Graph, diff: Diff) -> [FileChange] {
        var symbolsByFile: [String: [(line: Int, position: Int)]] = [:]
        var fileNode: [String: Int] = [:]
        for i in graph.nodes.indices {
            let n = graph.nodes[i]
            guard let f = n.sourceFile else { continue }
            if n.kind == .file {
                if fileNode[f] == nil { fileNode[f] = i }
            } else if let line = n.line, [.function, .method, .type, .route, .table].contains(n.kind) {
                symbolsByFile[f, default: []].append((line, i))
            }
        }
        let paths = Set(diff.hunks.keys).union(diff.added).union(diff.deleted)
        return paths.sorted().map { path in
            let decls = (symbolsByFile[path] ?? []).sorted { $0.line != $1.line ? $0.line < $1.line : $0.position < $1.position }
            var hit = Set<Int>()
            var header = false
            if diff.deleted.contains(path) || diff.added.contains(path) {
                hit.formUnion(decls.map(\.position))
            } else {
                for range in diff.hunks[path] ?? [] {
                    // Every symbol whose span [its line, next symbol's line) overlaps the range.
                    for (k, s) in decls.enumerated() {
                        let end = k + 1 < decls.count ? max(s.line, decls[k + 1].line - 1) : Int.max
                        if s.line <= range.upperBound && range.lowerBound <= end { hit.insert(s.position) }
                    }
                    // Header only means something when the file has declarations below it.
                    if let first = decls.first, range.lowerBound < first.line { header = true }
                }
            }
            let ordered = decls.map(\.position).filter { hit.contains($0) }
            var seen = Set<Int>()
            return FileChange(path: path, file: fileNode[path], symbols: ordered.filter { seen.insert($0).inserted },
                              header: header, added: diff.added.contains(path), deleted: diff.deleted.contains(path))
        }
    }

    // MARK: - git

    /// Accepts commits, branches, tags, `HEAD~3`, `main@{1}`; never an option or a range.
    public static func isSafeRef(_ ref: String) -> Bool {
        guard !ref.isEmpty, ref.count <= 100, !ref.hasPrefix("-"), !ref.contains("..") else { return false }
        return ref.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._/~^@{}-".unicodeScalars.contains($0) }
    }

    public enum GitError: Error, LocalizedError {
        case unsafeRef(String), unavailable, failed(String)
        public var errorDescription: String? {
            switch self {
            case .unsafeRef(let r): "'\(r)' is not a commit, branch or tag name Mapo accepts (e.g. 'main', 'HEAD~3', a commit hash)."
            case .unavailable: "git is not available on this Mac."
            case .failed(let m): "git: \(m)"
            }
        }
    }

    /// Diff of `since` against the working tree (committed + uncommitted
    /// tracked changes), plus untracked files as added. Paths are relative to
    /// `root`, limited to it.
    public static func diff(since: String, at root: URL) throws -> Diff {
        guard isSafeRef(since) else { throw GitError.unsafeRef(since) }
        guard GitInfo.isAvailable else { throw GitError.unavailable }
        let base = ["-c", "core.quotePath=false", "-C", root.path]
        let resolved = try git(base + ["rev-parse", "--verify", "--quiet", "--end-of-options", since + "^{commit}"])
        guard let commit = resolved.split(separator: "\n").first.map(String.init), GitInfo.isHex(commit) else {
            throw GitError.failed("unknown revision '\(since)'")
        }
        var d = parse(try git(base + ["diff", "--unified=0", "--no-renames", "--no-color", "--no-ext-diff", "--relative", commit, "--"]))
        let untracked = try git(base + ["ls-files", "--others", "--exclude-standard"])
        for p in untracked.split(separator: "\n") where !p.isEmpty { d.added.insert(String(p)) }
        return d
    }

    /// Synchronous `git` for the MCP server's blocking loop. Output is capped.
    static func git(_ args: [String], limit: Int = 8 << 20) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.environment = ProcessRunner.cleanEnvironment(extra: ["GIT_OPTIONAL_LOCKS": "0"])
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        // Drain stderr concurrently so a chatty git can't fill its pipe and stall.
        let errData = LockedData()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { errData.set(err.fileHandleForReading.readDataToEndOfFile()); errDone.signal() }
        var data = Data()
        let reader = out.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
        }
        p.waitUntilExit()
        errDone.wait()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData.get(), as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "exit \(p.terminationStatus)"
            throw GitError.failed(msg)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private final class LockedData: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
