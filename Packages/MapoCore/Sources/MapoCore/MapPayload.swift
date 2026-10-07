import Foundation

/// The columnar JSON the map renderer consumes (Map/src/types.ts `Payload`).
public struct MapPayload: Encodable, Sendable {
    public let version = 1
    public let nodes: Nodes
    public let edges: Edges
    public let communities: [String]
    public let folders: [String]
    /// Second-level areas ("apps/mobile/app/(sekmeler)/kesfet" → "kesfet"),
    /// named when the map is zoomed in.
    public let subfolders: [String]
    public let positions: [String: [Double]]?
    /// File ↔ file links lifted from symbol-level edges (A's function calls
    /// B's → A—B), weighted by how many symbol edges back them. Languages
    /// without file imports (Swift modules) would otherwise show bare files.
    public let fileLinks: FileLinks

    public struct FileLinks: Encodable, Sendable, Equatable {
        public var s: [Int] = []
        public var t: [Int] = []
        public var w: [Int] = []
    }

    public struct Nodes: Encodable, Sendable {
        public var id: [String] = []
        public var label: [String] = []
        public var kind: [Int] = []
        public var community: [Int] = []
        public var folder: [Int] = []
        public var test: [Int] = []
        public var degree: [Int] = []
        public var sub: [Int] = []
        /// Generated / minified / config files, hidden by default.
        public var noise: [Int] = []
        /// Repo-relative source path ("" for externals).
        public var path: [String] = []
        /// Index of the file a symbol lives in (-1 for files / externals).
        public var owner: [Int] = []
        /// Lines of code, files only (0 otherwise).
        public var lines: [Int] = []
        /// Days since the file last changed in git (-1 unknown).
        public var age: [Int] = []
    }

    public struct Edges: Encodable, Sendable {
        public var s: [Int] = []
        public var t: [Int] = []
        public var r: [Int] = []
    }

    public init(
        graph: Graph,
        positions: [String: [Double]]? = nil,
        noisyFiles: Set<String> = [],
        lineCounts: [String: Int] = [:],
        ages: [String: Int] = [:]
    ) {
        var nodes = Nodes()
        // Unique files: grouping weighs folders by files, not by how many
        // symbols they happen to declare.
        let folderNames = FolderGrouping(files: Array(Set(graph.nodes.compactMap(\.sourceFile))))
        var folderIndex: [String: Int] = [:]
        var folders: [String] = []
        var subIndex: [String: Int] = [:]
        var subfolders: [String] = []

        for (i, n) in graph.nodes.enumerated() {
            nodes.id.append(n.id)
            nodes.label.append(Self.displayLabel(n))
            nodes.kind.append(Self.kindCode(n.kind))
            nodes.community.append(n.community ?? 0)
            let folder = n.sourceFile.map(folderNames.group(of:)) ?? "—"
            if folderIndex[folder] == nil {
                folderIndex[folder] = folders.count
                folders.append(folder)
            }
            nodes.folder.append(folderIndex[folder]!)
            let sub = n.sourceFile.map { folderNames.subgroup(of: $0, in: folder) } ?? "—"
            let subKey = folder + "\u{0}" + sub
            if subIndex[subKey] == nil {
                subIndex[subKey] = subfolders.count
                subfolders.append(sub)
            }
            nodes.sub.append(subIndex[subKey]!)
            nodes.noise.append(n.sourceFile.map { noisyFiles.contains($0) || NoiseFilter.isNoise(path: $0) } == true ? 1 : 0)
            nodes.test.append(n.sourceFile.map(Self.isTestPath) == true ? 1 : 0)
            nodes.path.append(n.kind == .external ? "" : (n.sourceFile ?? ""))
            nodes.owner.append(n.kind == .file || n.kind == .external ? -1 : Self.owningFile(graph, i) ?? -1)
            nodes.lines.append(n.kind == .file ? (n.sourceFile.flatMap { lineCounts[$0] } ?? 0) : 0)
            nodes.age.append(n.kind == .file ? (n.sourceFile.flatMap { ages[$0] } ?? -1) : -1)
            let degree = graph.outgoing[i].count(where: { !graph.edges[$0].relation.isContainment })
                + graph.incoming[i].count(where: { !graph.edges[$0].relation.isContainment })
            nodes.degree.append(degree)
        }

        var edges = Edges()
        edges.s.reserveCapacity(graph.edges.count)
        for e in graph.edges {
            edges.s.append(e.sourcePosition)
            edges.t.append(e.targetPosition)
            edges.r.append(Self.relationCode(e.relation))
        }

        self.nodes = nodes
        self.edges = edges
        self.folders = folders
        self.subfolders = subfolders
        self.communities = Self.communityNames(graph)
        self.positions = positions
        self.fileLinks = Self.fileLinks(graph)
    }

    /// Walks containment upward (method → type → file).
    static func owningFile(_ graph: Graph, _ position: Int) -> Int? {
        var cur = position
        for _ in 0..<8 {
            guard let p = graph.parent(of: cur) else { return nil }
            if graph.nodes[p].kind == .file { return p }
            cur = p
        }
        return nil
    }

    public static func fileLinks(_ graph: Graph) -> FileLinks {
        var fileNode: [String: Int] = [:]
        for (i, n) in graph.nodes.enumerated() where n.kind == .file {
            if let f = n.sourceFile { fileNode[f] = i }
        }
        struct Pair: Hashable { let a: Int, b: Int }
        var counts: [Pair: Int] = [:]
        for e in graph.edges where !e.relation.isContainment {
            guard let fa = graph.nodes[e.sourcePosition].sourceFile,
                  let fb = graph.nodes[e.targetPosition].sourceFile,
                  fa != fb,
                  let a = fileNode[fa], let b = fileNode[fb]
            else { continue }
            counts[Pair(a: a, b: b), default: 0] += 1
        }
        var links = FileLinks()
        for (pair, w) in counts.sorted(by: { ($0.key.a, $0.key.b) < ($1.key.a, $1.key.b) }) {
            links.s.append(pair.a)
            links.t.append(pair.b)
            links.w.append(w)
        }
        return links
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    // MARK: - Mapping

    static func displayLabel(_ n: Node) -> String {
        switch n.kind {
        case .function, .method: return n.name
        default: return n.label
        }
    }

    static func kindCode(_ k: Node.Kind) -> Int {
        switch k {
        case .file: 0
        case .function: 1
        case .method: 2
        case .type: 3
        case .symbol: 4
        case .external: 5
        case .document: 6
        }
    }

    static func relationCode(_ r: Relation) -> Int {
        if r.isContainment { return 0 }
        if r.isCall { return 1 }
        if r.isImport { return 2 }
        return 3
    }

    public static func isTestPath(_ path: String) -> Bool {
        let p = "/" + path.lowercased()
        return p.contains("/__tests__/") || p.contains("/test/") || p.contains("/tests/")
            || p.contains(".test.") || p.contains(".spec.") || p.contains("/spec/")
            || p.contains("tests/") && p.hasSuffix(".swift")
    }

    /// Community name = its best-connected member's name (deterministic,
    /// no LLM). Index-aligned with community ids; gaps get "".
    static func communityNames(_ graph: Graph) -> [String] {
        var best: [Int: (degree: Int, name: String)] = [:]
        for (i, n) in graph.nodes.enumerated() {
            guard let c = n.community, n.kind != .external else { continue }
            let degree = graph.incoming[i].count + graph.outgoing[i].count
            let name = n.kind == .file ? ((n.label as NSString).deletingPathExtension) : n.name
            if degree > (best[c]?.degree ?? -1) { best[c] = (degree, name) }
        }
        guard let maxID = best.keys.max() else { return [] }
        return (0...maxID).map { best[$0]?.name ?? "" }
    }
}

extension Relation {
    var isContainment: Bool { self == .contains || self == .method }
}

/// Groups file paths into readable top-level areas. A first component that
/// holds most of the code (`apps/`, `packages/`, `src/`) is split one level
/// deeper so `apps/mobile` and `apps/api` stay apart.
struct FolderGrouping {
    private let deep: Set<String>

    init(files: [String]) {
        // Split a top-level folder only when it really holds several big
        // areas: at least two of its sub-folders with ≥10% of all files each
        // (apps/mobile + apps/api). One big sub-folder plus crumbs stays whole.
        var subCounts: [String: [String: Int]] = [:]
        var total = 0
        for f in files {
            let parts = f.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count > 1 else { continue }
            total += 1
            if parts.count > 2 { subCounts[String(parts[0]), default: [:]][String(parts[1]), default: 0] += 1 }
        }
        let threshold = max(2, Double(total) * 0.10)
        deep = Set(subCounts.compactMap { first, subs in
            subs.values.filter { Double($0) >= threshold }.count >= 2 ? first : nil
        })
    }

    /// The folder one level below `group` that holds `path`; files sitting
    /// directly in the group are "" (no sub-area label). Route-group
    /// segments like "(sekmeler)" and underscore helpers are skipped so the
    /// name is the one people use.
    func subgroup(of path: String, in group: String) -> String {
        guard group != "/", path.hasPrefix(group + "/") else { return "" }
        var rest = path.dropFirst(group.count + 1).split(separator: "/").dropLast()
        while let first = rest.first, (first.hasPrefix("(") && first.hasSuffix(")")) || ["src", "app", "lib", "Sources"].contains(String(first)) && rest.count > 1 {
            rest = rest.dropFirst()
        }
        return rest.first.map(String.init) ?? ""
    }

    func group(of path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return "/" }
        let first = String(parts[0])
        if deep.contains(first), parts.count > 2 { return "\(first)/\(parts[1])" }
        return first
    }
}

/// Files that clutter a map without explaining the code: build output,
/// lockfiles, minified bundles, tool configuration.
public enum NoiseFilter {
    static let configNames: Set<String> = [
        "package.json", "package-lock.json", "tsconfig.json", "jsconfig.json", "yarn.lock", "pnpm-lock.yaml",
        "bun.lockb", "Package.resolved", "Podfile.lock", "Cargo.lock", "poetry.lock", "composer.lock",
        "app.json", "eas.json", "babel.config.js", "metro.config.js", "jest.config.js", "eslint.config.js",
        ".eslintrc.js", ".prettierrc.js", "tailwind.config.js", "postcss.config.js", "vite.config.ts",
        "next.config.js", "next.config.mjs", "wrangler.toml", "project.yml",
    ]

    public static func isNoise(path: String) -> Bool {
        let p = path.lowercased()
        let name = (path as NSString).lastPathComponent
        if configNames.contains(name) { return true }
        if p.hasSuffix(".min.js") || p.hasSuffix(".min.css") || p.hasSuffix(".map") || p.hasSuffix(".lock") { return true }
        if p.hasSuffix(".d.ts") { return true }
        for dir in ["/dist/", "/build/", "/out/", "/.next/", "/vendor/", "/node_modules/", "/generated/", "/__generated__/", "/coverage/", "/deriveddata/"] {
            if ("/" + p).contains(dir) { return true }
        }
        return false
    }

    /// A JS/CSS file whose lines are absurdly long is a bundle, not source.
    /// Reads at most 64 KB.
    public static func looksMinified(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["js", "mjs", "cjs", "css"].contains(ext),
              let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 65_536), data.count > 4_000 else { return false }
        let newlines = data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        return data.count / max(1, newlines) > 400
    }
}
