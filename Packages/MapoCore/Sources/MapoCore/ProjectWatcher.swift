import CoreServices
import Foundation

/// What happened in a project folder, after debouncing.
public struct ProjectChange: Sendable, Equatable {
    /// Repo-relative paths of source files that changed.
    public var files: Set<String> = []
    /// HEAD or refs moved: commit, checkout, pull, rebase.
    public var git = false

    public var isEmpty: Bool { files.isEmpty && !git }

    public init(files: Set<String> = [], git: Bool = false) {
        self.files = files
        self.git = git
    }
}

/// Decides which file-system events matter for a code map.
public enum ChangeFilter {
    /// Folders whose contents never belong on the map.
    static let ignoredDirectories: Set<String> = [
        "node_modules", ".build", "build", "dist", "out", "DerivedData", ".next", ".expo", ".turbo",
        ".cache", "coverage", "Pods", ".gradle", "target", "vendor", "__pycache__", ".venv", "venv",
        ".idea", ".vscode", "graphify-out", ".swiftpm", ".wrangler",
    ]

    /// Extensions graphify extracts code from (tree-sitter languages).
    static let codeExtensions: Set<String> = [
        "swift", "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs", "py", "go", "rs", "java", "kt", "kts",
        "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "cs", "rb", "php", "scala", "lua", "zig",
        "ex", "exs", "jl", "v", "sv", "f90", "f", "sh", "bash", "ps1", "groovy", "gradle", "json",
    ]

    public enum Kind: Equatable {
        case source(String)
        case git
        case ignored
    }

    /// Classifies an absolute path inside `root`.
    public static func classify(_ path: String, root: String) -> Kind {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(base) else { return .ignored }
        let rel = String(path.dropFirst(base.count))
        let parts = rel.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first else { return .ignored }

        if first == ".git" {
            // HEAD (checkout), refs/heads/* (commit), packed-refs, ORIG_HEAD
            // (rebase/merge). Index and object churn are noise.
            guard parts.count >= 2 else { return .ignored }
            let second = parts[1]
            if second == "HEAD" || second == "packed-refs" || second == "ORIG_HEAD" || second == "FETCH_HEAD" { return .git }
            if second == "refs", parts.count >= 3, parts[2] == "heads" || parts[2] == "remotes" { return .git }
            return .ignored
        }
        for p in parts.dropLast() where ignoredDirectories.contains(String(p)) || (p.hasPrefix(".") && p != ".github") {
            return .ignored
        }
        guard let name = parts.last, !name.hasPrefix(".") else { return .ignored }
        let ext = (name as NSString).pathExtension.lowercased()
        guard codeExtensions.contains(ext) else { return .ignored }
        // Editors' temp files: "foo.ts~", "foo.ts.swp" are filtered by the
        // extension check; "foo.tmp.ts"-style atomic writes still count, harmless.
        return .source(rel)
    }
}

/// Watches a project folder with FSEvents and reports debounced changes.
///
/// FSEvents coalesces at the kernel level (`latency`); on top of that we wait
/// for a quiet period so a branch switch touching 300 files is one change.
public final class ProjectWatcher: @unchecked Sendable {
    public let root: String
    private let quiet: TimeInterval
    private let onChange: @Sendable (ProjectChange) -> Void

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "mapo.watcher", qos: .utility)
    private var pending = ProjectChange()
    private var flushItem: DispatchWorkItem?

    public init(root: URL, quiet: TimeInterval = 2.0, onChange: @escaping @Sendable (ProjectChange) -> Void) {
        // realpath, not resolvingSymlinksInPath: Foundation shortens
        // /private/var → /var, but FSEvents reports the real /private path,
        // and a mismatch silently drops every event.
        self.root = Self.canonical(root.path)
        self.quiet = quiet
        self.onChange = onChange
    }

    deinit { stop() }

    static func canonical(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.receive(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        flushItem?.cancel()
    }

    /// Runs on `queue`.
    func receive(_ paths: [String]) {
        var touched = false
        for path in paths {
            switch ChangeFilter.classify(path, root: root) {
            case .source(let rel): pending.files.insert(rel); touched = true
            case .git: pending.git = true; touched = true
            case .ignored: break
            }
        }
        guard touched else { return }
        flushItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        flushItem = item
        queue.asyncAfter(deadline: .now() + quiet, execute: item)
    }

    private func flush() {
        let change = pending
        pending = ProjectChange()
        if !change.isEmpty { onChange(change) }
    }
}
