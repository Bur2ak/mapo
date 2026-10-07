import Foundation

/// Cloning and fast-forward updating of GitHub repositories.
///
/// The token reaches git through `GIT_CONFIG_*` environment variables as an
/// HTTP header for the duration of one command: it is never written to
/// `.git/config`, never part of a URL, never on the command line (where any
/// local user could see it with `ps`).
public enum RepoSync {
    public enum SyncError: Error, LocalizedError, Equatable {
        case cloneFailed(String)
        case destinationExists(String)

        public var errorDescription: String? {
            switch self {
            case .cloneFailed(let m): String(localized: "Depo indirilemedi: \(m)")
            case .destinationExists(let p): String(localized: "Bu konumda zaten bir klasör var: \(p)")
            }
        }
    }

    public enum UpdateResult: Equatable, Sendable {
        case upToDate
        case updated(commits: Int)
        /// Local edits or diverged history: left untouched.
        case skipped(reason: String)
    }

    static func environment(token: String?) -> [String: String] {
        var extra = ["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/true"]
        if let token {
            let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
            extra["GIT_CONFIG_COUNT"] = "1"
            extra["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraHeader"
            extra["GIT_CONFIG_VALUE_0"] = "Authorization: Basic \(basic)"
        }
        return ProcessRunner.cleanEnvironment(extra: extra)
    }

    /// Clones `url` into `destination` (which must not exist yet).
    public static func clone(_ url: URL, to destination: URL, token: String?,
                             progress: (@Sendable (String) -> Void)? = nil) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            throw SyncError.destinationExists(destination.path)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["clone", "--progress", url.absoluteString, destination.path],
            environment: environment(token: token)
        ) { line in progress?(line) }
        guard r.status == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw SyncError.cloneFailed(Self.redact(r.stderr, token: token).split(separator: "\n").suffix(2).joined(separator: " "))
        }
    }

    /// `git fetch` + fast-forward only. Never touches a dirty work tree or a
    /// branch with local commits.
    public static func update(_ repo: URL, token: String?) async -> UpdateResult {
        let env = environment(token: token)
        func git(_ args: [String]) async -> ProcessRunner.Result? {
            try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/git"),
                                         arguments: ["-C", repo.path] + args, environment: env)
        }
        guard let status = await git(["status", "--porcelain", "--untracked-files=no"]), status.status == 0 else {
            return .skipped(reason: String(localized: "git durumu okunamadı"))
        }
        if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .skipped(reason: String(localized: "kaydedilmemiş değişiklikler var"))
        }
        guard let fetch = await git(["fetch", "--quiet"]), fetch.status == 0 else {
            return .skipped(reason: String(localized: "uzak depoya ulaşılamadı"))
        }
        guard let counts = await git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]), counts.status == 0 else {
            return .skipped(reason: String(localized: "izlenen dal yok"))
        }
        let parts = counts.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard parts.count == 2 else { return .skipped(reason: String(localized: "git çıktısı okunamadı")) }
        let (ahead, behind) = (parts[0], parts[1])
        if behind == 0 { return .upToDate }
        if ahead > 0 { return .skipped(reason: String(localized: "yerel commit'ler var")) }
        guard let merge = await git(["merge", "--ff-only", "--quiet", "@{upstream}"]), merge.status == 0 else {
            return .skipped(reason: String(localized: "hızlı ileri alma yapılamadı"))
        }
        return .updated(commits: behind)
    }

    /// Where Mapo clones a repository by default.
    public static func defaultDestination(for repo: GitHub.Repository, paths: MapoPaths) -> URL {
        paths.reposDir.appendingPathComponent(repo.owner, isDirectory: true).appendingPathComponent(repo.name, isDirectory: true)
    }

    static func redact(_ text: String, token: String?) -> String {
        guard let token, !token.isEmpty else { return text }
        return text.replacingOccurrences(of: token, with: "•••")
    }
}
