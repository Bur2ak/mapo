import Foundation

/// Minimal git queries via the system `git`. Every call is read-only.
public enum GitInfo {
    public struct Head: Sendable, Equatable {
        public let commit: String
        public let branch: String?
    }

    /// nil when `root` is not inside a git work tree (or git is missing).
    public static func head(at root: URL) async -> Head? {
        guard let commit = await git(["rev-parse", "HEAD"], at: root), isHex(commit) else { return nil }
        let branch = await git(["rev-parse", "--abbrev-ref", "HEAD"], at: root)
        return Head(commit: commit, branch: branch == "HEAD" ? nil : branch)
    }

    /// Commits reachable from HEAD but not from `commit`. nil if unknown
    /// (e.g. the indexed commit was rebased away).
    public static func commitsSince(_ commit: String, at root: URL) async -> Int? {
        guard isHex(commit) else { return nil }
        return await git(["rev-list", "--count", "\(commit)..HEAD"], at: root).flatMap(Int.init)
    }

    /// Files changed in the last `count` commits plus the working tree.
    public static func recentlyChangedFiles(at root: URL, commits count: Int = 5) async -> Set<String> {
        var files = Set<String>()
        if let log = await git(["log", "-\(count)", "--name-only", "--pretty=format:"], at: root) {
            files.formUnion(log.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
        }
        if let status = await git(["status", "--porcelain"], at: root) {
            for line in status.split(separator: "\n") where line.count > 3 {
                var path = String(line.dropFirst(3))
                if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
                files.insert(path.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        }
        return files
    }

    /// Days since each file last changed: newest commit touching it among the
    /// last `commits`, or 0 for uncommitted edits. Files older than that
    /// window are absent (shown as "older").
    public static func fileAges(at root: URL, commits: Int = 400, now: Date = .now) async -> [String: Int] {
        var ages: [String: Int] = [:]
        if let log = await git(["log", "-\(commits)", "--name-only", "--no-renames", "--pretty=format:@%ct"], at: root) {
            var stamp: Date?
            for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("@"), let t = TimeInterval(line.dropFirst()) {
                    stamp = Date(timeIntervalSince1970: t)
                } else if let stamp, ages[String(line)] == nil {
                    ages[String(line)] = max(0, Int(now.timeIntervalSince(stamp) / 86_400))
                }
            }
        }
        for path in await recentlyChangedFiles(at: root, commits: 0) { ages[path] = 0 }
        return ages
    }

    static func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy(\.isHexDigit)
    }

    /// `/usr/bin/git` is an xcode-select stub until Command Line Tools are
    /// installed; calling it then pops the installer dialog every time.
    public static let isAvailable: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    static func git(_ args: [String], at root: URL) async -> String? {
        guard isAvailable else { return nil }
        let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", root.path] + args,
            environment: ProcessRunner.cleanEnvironment(extra: ["GIT_OPTIONAL_LOCKS": "0"])
        )
        guard let result, result.status == 0 else { return nil }
        // Trailing only: porcelain status lines start with a meaningful space.
        var out = Substring(result.stdout)
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return String(out)
    }
}
