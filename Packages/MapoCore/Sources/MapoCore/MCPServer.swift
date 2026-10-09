import Foundation

/// Model Context Protocol server over stdio (JSON-RPC 2.0, one message per line).
///
/// Exposes Mapo's maps to coding agents — Claude Code, Codex, Cursor,
/// Claude Desktop — as read-only tools. No network: the agent spawns
/// `mapo-mcp` and talks to it over stdin/stdout.
///
/// Agents get answers they can act on: real file paths and line numbers,
/// plus how fresh the map is, so they never mistake the map for the code.
public final class MCPServer: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"
    static let supportedVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let paths: MapoPaths
    private let serverVersion: String
    private var cache: [UUID: (modified: Date, graph: Graph, search: SearchIndex)] = [:]
    /// Fuzzy resolutions made while answering the current call.
    private var approximate: [String] = []

    public init(paths: MapoPaths, version: String) {
        self.paths = paths
        self.serverVersion = version
    }

    // MARK: - Transport

    /// Blocking loop: reads requests from stdin until EOF.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = handle(line: line) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }

    /// One JSON-RPC message in, zero or one out. Notifications get no reply.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let msg = parsed as? [String: Any] else {
            // MCP 2025-06-18 removed JSON-RPC batching.
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]])
        }
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]
        guard id != nil else { return nil }  // notification
        guard let method = msg["method"] as? String else {
            return encode(["jsonrpc": "2.0", "id": id!, "error": ["code": -32600, "message": "Invalid Request: missing method"]])
        }

        let result: Any
        do {
            switch method {
            case "initialize":
                let requested = params["protocolVersion"] as? String ?? Self.protocolVersion
                result = [
                    // Echo a version we also speak; otherwise offer our latest.
                    "protocolVersion": Self.supportedVersions.contains(requested) ? requested : Self.protocolVersion,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "mapo", "title": "Mapo", "version": serverVersion],
                    "instructions": Self.instructions,
                ]
            case "ping":
                result = [String: Any]()
            case "tools/list":
                result = ["tools": Self.tools]
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                guard Self.tools.contains(where: { $0["name"] as? String == name }) else {
                    throw RPCError(code: -32602, message: "Unknown tool: \(name)")
                }
                do {
                    let text = try call(name, args)
                    result = ["content": [["type": "text", "text": text]], "isError": false]
                } catch {
                    // Tool errors are results the model can read and react to.
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    result = ["content": [["type": "text", "text": message]], "isError": true]
                }
            default:
                throw RPCError(code: -32601, message: "Method not found: \(method)")
            }
        } catch let e as RPCError {
            return encode(["jsonrpc": "2.0", "id": id!, "error": ["code": e.code, "message": e.message]])
        } catch {
            return encode(["jsonrpc": "2.0", "id": id!, "error": ["code": -32603, "message": "\(error)"]])
        }
        return encode(["jsonrpc": "2.0", "id": id!, "result": result])
    }

    struct RPCError: Error { let code: Int; let message: String }

    struct ToolError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func encode(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Tools

    static let instructions = """
    Mapo keeps a live map of the user's codebases (files, functions, types, and who calls/imports whom), \
    built locally from the source. Use it to orient before reading code: find where something lives, \
    who depends on it, and what a change may affect. Every answer includes file paths and line numbers — \
    open those files to confirm, since the map can lag the working tree by a few seconds (see `freshness`).
    """

    static var tools: [[String: Any]] { [
        tool("mapo_projects", "List projects Mapo has mapped, with root path and how fresh each map is. Call this first to get a project name.", [:], []),
        tool("mapo_search", "Fuzzy-find symbols and files by name (camelCase-aware, e.g. 'usrSvc' finds 'UserService').",
             ["project": projectProp, "query": ["type": "string", "description": "Name or fragment to find."],
              "limit": ["type": "integer", "description": "Max results (default 15)."]], ["project", "query"]),
        tool("mapo_node", "Describe one symbol or file: kind, location, and counts of callers/callees/importers. Accepts a name or an id from another tool.",
             ["project": projectProp, "symbol": symbolProp], ["project", "symbol"]),
        tool("mapo_callers", "Who calls this function or method.", ["project": projectProp, "symbol": symbolProp], ["project", "symbol"]),
        tool("mapo_callees", "What this function or method calls.", ["project": projectProp, "symbol": symbolProp], ["project", "symbol"]),
        tool("mapo_file_dependencies", "For a file: which files it uses and which files use it, with edge counts.",
             ["project": projectProp, "path": ["type": "string", "description": "Repo-relative file path or file name."]], ["project", "path"]),
        tool("mapo_path", "Shortest chain of calls/imports from A to B — how does A reach B?",
             ["project": projectProp, "from": symbolProp, "to": symbolProp], ["project", "from", "to"]),
        tool("mapo_endpoints", "HTTP endpoints the server defines (Hono/Express/Next…), where each is defined and which client functions call it; plus database tables with their readers/writers. Use it to cross the client↔server and code↔database boundary.",
             ["project": projectProp, "query": ["type": "string", "description": "Optional filter on the path or table name (e.g. '/kulup', 'profiles')."]], ["project"]),
        tool("mapo_impact", "Blast radius: what may break if this symbol or file changes, grouped by distance.",
             ["project": projectProp, "symbol": symbolProp, "depth": ["type": "integer", "description": "Rings to walk (1–4, default 2)."]],
             ["project", "symbol"]),
    ] }

    private static var projectProp: [String: Any] { ["type": "string", "description": "Project name or root path, from mapo_projects."] }
    private static var symbolProp: [String: Any] { ["type": "string", "description": "Symbol or file name (e.g. 'kulupSohbetiAc', 'api.ts'), or a node id."] }

    private static func tool(_ name: String, _ description: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ]
    }

    func call(_ name: String, _ a: [String: Any]) throws -> String {
        approximate = []
        if name == "mapo_projects" { return try listProjects() }
        let (project, graph, search) = try load(a["project"] as? String)
        var out: String
        switch name {
        case "mapo_search":
            let q = try str(a, "query")
            let limit = min(50, max(1, a["limit"] as? Int ?? 15))
            let hits = search.search(q, limit: limit)
            out = hits.isEmpty ? "No matches for '\(q)'." : hits.map { line(graph, $0.position) }.joined(separator: "\n")
        case "mapo_node":
            let p = try resolve(try str(a, "symbol"), graph, search)
            let n = graph.nodes[p]
            out = """
            \(line(graph, p))
            id: \(n.id)
            callers: \(graph.callers(of: p).count) · callees: \(graph.callees(of: p).count) · importers: \(graph.importers(of: p).count) · imports: \(graph.imports(of: p).count) · contains: \(graph.children(of: p).count)
            """
            // HTTP / SQL bridges, listed: they are what an agent can't grep for.
            for (title, rel, incoming) in [("Requested by", Relation.requests, true), ("Requests", .requests, false),
                                           ("Read by", .reads, true), ("Written by", .writes, true),
                                           ("Reads tables", .reads, false), ("Writes tables", .writes, false)] {
                let ps = bridged(graph, p, rel, incoming: incoming)
                if !ps.isEmpty { out += "\n" + list(title, ps, graph) }
            }
        case "mapo_callers":
            let p = try resolve(try str(a, "symbol"), graph, search)
            out = list("Callers of \(graph.nodes[p].name)", unique(graph.callers(of: p).map(\.node)), graph)
        case "mapo_callees":
            let p = try resolve(try str(a, "symbol"), graph, search)
            out = list("Called by \(graph.nodes[p].name)", unique(graph.callees(of: p).map(\.node)), graph)
        case "mapo_file_dependencies":
            let p = try resolveFile(try str(a, "path"), graph, search)
            let deps = graph.fileDependencies(of: p)
            func fmt(_ d: [Graph.FileDependency]) -> String {
                d.isEmpty ? "  (none)" : d.prefix(40).map { "  \(graph.nodes[$0.file].sourceFile ?? graph.nodes[$0.file].label)  ×\($0.weight)" }.joined(separator: "\n")
            }
            out = "\(graph.nodes[p].sourceFile ?? graph.nodes[p].label)\nUses:\n\(fmt(deps.uses))\nUsed by:\n\(fmt(deps.usedBy))"
        case "mapo_path":
            let from = try resolve(try str(a, "from"), graph, search)
            let to = try resolve(try str(a, "to"), graph, search)
            guard let path = graph.shortestPath(from: from, to: to) else {
                out = "No connection between \(graph.nodes[from].name) and \(graph.nodes[to].name) in the map."
                break
            }
            let steps = zip(path.nodes, [nil] + path.edges.map(Optional.some)).map { node, edge -> String in
                let rel = edge.map { "  —\(graph.edges[$0].relation.rawValue)→ " } ?? "  "
                return rel + line(graph, node)
            }
            out = (path.directed ? "Path:" : "Related (ignoring direction):") + "\n" + steps.joined(separator: "\n")
        case "mapo_endpoints":
            let q = (a["query"] as? String)?.lowercased() ?? ""
            let routes = graph.nodes.indices.filter { graph.nodes[$0].kind == .route && (q.isEmpty || graph.nodes[$0].label.lowercased().contains(q)) }
            let tables = graph.nodes.indices.filter { graph.nodes[$0].kind == .table && (q.isEmpty || graph.nodes[$0].label.lowercased().contains(q)) }
            if routes.isEmpty && tables.isEmpty {
                out = q.isEmpty ? "No HTTP endpoints or tables found in this project." : "No endpoint or table matches '\(q)'."
                break
            }
            var parts: [String] = []
            if !routes.isEmpty {
                parts.append("Endpoints (\(routes.count)):\n" + routes.prefix(120).map { r in
                    let callers = bridged(graph, r, .requests, incoming: true)
                    let who = callers.prefix(5).map { graph.nodes[$0].name }.joined(separator: ", ")
                    return "  " + line(graph, r) + "  ← \(callers.count) caller\(callers.count == 1 ? "" : "s")" + (who.isEmpty ? "" : ": \(who)")
                }.joined(separator: "\n") + (routes.count > 120 ? "\n  … \(routes.count - 120) more" : ""))
            }
            if !tables.isEmpty {
                parts.append("Tables (\(tables.count)):\n" + tables.prefix(120).map { t in
                    "  " + line(graph, t) + "  read by \(bridged(graph, t, .reads, incoming: true).count), written by \(bridged(graph, t, .writes, incoming: true).count)"
                }.joined(separator: "\n"))
            }
            out = parts.joined(separator: "\n\n") + "\n(Inferred from code patterns; confirm in the files.)"
        case "mapo_impact":
            let p = try resolve(try str(a, "symbol"), graph, search)
            let depth = min(4, max(1, a["depth"] as? Int ?? 2))
            let rings = graph.impact(of: p, maxDepth: depth)
            out = rings.enumerated().dropFirst().map { i, ring in
                "Distance \(i) (\(ring.count)):\n" + ring.prefix(40).map { "  " + line(graph, $0) }.joined(separator: "\n")
                    + (ring.count > 40 ? "\n  … \(ring.count - 40) more" : "")
            }.joined(separator: "\n")
            if out.isEmpty { out = "Nothing in the map depends on \(graph.nodes[p].name)." }
        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
        let note = approximate.isEmpty ? "" : "note: approximate match — " + approximate.joined(separator: "; ") + ". Use the exact name or an id if this is not what you meant.\n"
        return note + out + "\n\n" + freshness(project, graph)
    }

    // MARK: - Data

    private func listProjects() throws -> String {
        let projects = try libraryProjects()
        guard !projects.isEmpty else { return "Mapo has no projects yet. Add one in the Mapo app." }
        return projects.map { p in
            let idx = p.lastIndex.map { "map: \($0.fileCount) files, built \(Self.iso($0.finishedAt))\($0.commit.map { " at " + $0.prefix(7) } ?? "")" } ?? "no map yet"
            return "- \(p.name) — \(p.rootPath) — \(idx)"
        }.joined(separator: "\n")
    }

    private func libraryProjects() throws -> [Project] {
        guard let data = try? Data(contentsOf: paths.libraryFile) else { return [] }
        struct Stored: Decodable { var projects: [Project] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(Stored.self, from: data))?.projects ?? []
    }

    private func load(_ ref: String?) throws -> (Project, Graph, SearchIndex) {
        let projects = try libraryProjects()
        let project: Project
        if let ref, !ref.isEmpty {
            let r = ref.lowercased()
            guard let p = projects.first(where: { $0.name.lowercased() == r || $0.rootPath == ref || $0.id.uuidString.lowercased() == r })
                ?? projects.first(where: { $0.name.lowercased().contains(r) }) else {
                throw ToolError(message: "No Mapo project matches '\(ref)'. Known: \(projects.map(\.name).joined(separator: ", "))")
            }
            project = p
        } else if projects.count == 1 {
            project = projects[0]
        } else {
            throw ToolError(message: "Specify `project`. Known: \(projects.map(\.name).joined(separator: ", "))")
        }
        let url = paths.graphFile(project.id)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              var modified = attrs[.modificationDate] as? Date else {
            throw ToolError(message: "\(project.name) has no map yet. Open Mapo and build it.")
        }
        // Bridges are written just after the graph: either changing reloads.
        let bridges = url.deletingLastPathComponent().appendingPathComponent(Bridges.fileName).path
        if let b = (try? FileManager.default.attributesOfItem(atPath: bridges))?[.modificationDate] as? Date, b > modified { modified = b }
        if let c = cache[project.id], c.modified == modified { return (project, c.graph, c.search) }
        let graph: Graph
        do {
            graph = try GraphLoader.load(from: url).0
        } catch {
            // The engine may be rewriting the file right now: one retry.
            Thread.sleep(forTimeInterval: 0.5)
            graph = try GraphLoader.load(from: url).0
        }
        if cache.count >= 4, let oldest = cache.keys.first { cache[oldest] = nil }
        let search = SearchIndex(graph: graph)
        cache[project.id] = (modified, graph, search)
        return (project, graph, search)
    }

    private func resolve(_ ref: String, _ graph: Graph, _ search: SearchIndex) throws -> Int {
        if let p = graph.position(of: ref) { return p }
        let hits = search.search(ref, limit: 5)
        let exact = hits.first { graph.nodes[$0.position].name == ref || graph.nodes[$0.position].label == ref }
        guard let hit = exact ?? hits.first else { throw ToolError(message: "No symbol matches '\(ref)'. Try mapo_search.") }
        if exact == nil {
            approximate.append("'\(ref)' → closest match '\(graph.nodes[hit.position].name)'")
        }
        return hit.position
    }

    private func resolveFile(_ ref: String, _ graph: Graph, _ search: SearchIndex) throws -> Int {
        if let p = graph.nodes.indices.first(where: { graph.nodes[$0].kind == .file && graph.nodes[$0].sourceFile == ref }) { return p }
        if let p = graph.nodes.indices.first(where: { graph.nodes[$0].kind == .file && (graph.nodes[$0].sourceFile?.hasSuffix("/" + ref) ?? false) }) { return p }
        let p = try resolve(ref, graph, search)
        if graph.nodes[p].kind == .file { return p }
        if let parent = graph.parent(of: p) { return parent }
        throw ToolError(message: "'\(ref)' is not a file in the map.")
    }

    private func freshness(_ p: Project, _ g: Graph) -> String {
        let commit = p.lastIndex?.commit.map { " at commit " + $0.prefix(7) } ?? ""
        let when = p.lastIndex.map { " built " + Self.iso($0.finishedAt) } ?? ""
        return "freshness: map of \(p.name)\(when)\(commit) (\(g.nodes.count) nodes). Verify in source before editing."
    }

    // MARK: - Formatting

    private func line(_ g: Graph, _ p: Int) -> String {
        let n = g.nodes[p]
        let loc = n.sourceFile.map { f in n.line.map { "\(f):\($0)" } ?? f } ?? "(external)"
        let name = n.kind == .file ? n.label : n.name
        return "\(n.kind.rawValue) \(name)  \(loc)"
    }

    private func bridged(_ g: Graph, _ p: Int, _ r: Relation, incoming: Bool) -> [Int] {
        var seen = Set<Int>()
        return (incoming ? g.incoming[p] : g.outgoing[p]).compactMap { e -> Int? in
            let edge = g.edges[e]
            guard edge.relation == r else { return nil }
            let other = incoming ? edge.sourcePosition : edge.targetPosition
            return seen.insert(other).inserted ? other : nil
        }
    }

    private func list(_ title: String, _ positions: [Int], _ g: Graph) -> String {
        guard !positions.isEmpty else { return "\(title): none in the map." }
        let shown = positions.prefix(60).map { "  " + line(g, $0) }.joined(separator: "\n")
        return "\(title) (\(positions.count)):\n\(shown)" + (positions.count > 60 ? "\n  … \(positions.count - 60) more" : "")
    }

    private func unique(_ ps: [Int]) -> [Int] {
        var seen = Set<Int>()
        return ps.filter { seen.insert($0).inserted }
    }

    private func str(_ a: [String: Any], _ key: String) throws -> String {
        guard let v = a[key] as? String, !v.isEmpty else { throw ToolError(message: "Missing argument `\(key)`.") }
        return v
    }

    private static func iso(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }
}
