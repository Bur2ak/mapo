import Foundation

/// Links graphify can't see because they cross a process boundary:
///
/// - **HTTP:** server route definitions (Hono, Express, Fastify-style
///   `router.get('/x', …)`, mounted with `app.route('/api', r)` /
///   `app.use('/api', r)`; Next.js `app/**/route.ts` and `pages/api/**`)
///   become `route` nodes inside their file. Client calls (`fetch`,
///   `get/post/…` wrappers, axios, ky) whose path matches a route get a
///   `requests` edge from the calling function to it.
/// - **SQL:** `CREATE TABLE` in `.sql` files becomes a `table` node inside
///   that file; code that mentions the table after `FROM / JOIN` (reads) or
///   `INTO / UPDATE / DELETE FROM` (writes) gets a `reads` / `writes` edge.
///
/// Heuristic by nature, so every edge is marked INFERRED. The result is a
/// small node-link JSON next to graphify's (`mapo-bridges.json`) that
/// `GraphLoader` merges in, for the app and for agents alike.
public enum Bridges {
    public static let fileName = "mapo-bridges.json"

    public struct Output: Sendable, Equatable {
        public var routes = 0
        public var requests = 0
        public var tables = 0
        public var queries = 0
    }

    /// Extracts and writes `<graphDir>/mapo-bridges.json` (removes a stale one
    /// when nothing is found). Never throws: a failure only means no bridges.
    @discardableResult
    public static func write(root: URL, graph: Graph, graphDir: URL) -> Output {
        let url = graphDir.appendingPathComponent(fileName)
        let (doc, out) = extract(root: root, graph: graph)
        if doc.nodes.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: url, options: .atomic)
        }
        return out
    }

    // MARK: - Extraction

    struct Doc: Codable, Equatable {
        var nodes: [N] = []
        var links: [L] = []
        struct N: Codable, Equatable {
            let id: String
            let label: String
            let type: String
            let source_file: String
            let source_location: String
        }
        struct L: Codable, Equatable {
            let source: String
            let target: String
            let relation: String
            let confidence: String
            let source_file: String
            let source_location: String
        }
    }

    struct Route: Equatable {
        let method: String
        let path: String
        let file: String
        let line: Int
        var segments: [Substring] { path.split(separator: "/") }
    }

    struct Call: Equatable {
        let method: String
        let path: String
        let file: String
        let line: Int
        /// `yonetim` in `yonetim.request(…)`: narrows router-relative paths.
        var receiver: String? = nil
    }

    static func extract(root: URL, graph: Graph) -> (Doc, Output) {
        let clock = ContinuousClock()
        var lap = clock.now
        func tick(_ name: String) {
            guard ProcessInfo.processInfo.environment["MAPO_BRIDGES_TIMING"] != nil else { return }
            print("  ⏱ \(name): \(clock.now - lap)"); lap = clock.now
        }
        defer { tick("end") }
        var doc = Doc()
        var out = Output()

        // Files graphify knows, plus schema files (.sql / .prisma) it doesn't.
        var fileNodeID: [String: String] = [:]
        for n in graph.nodes where n.kind == .file {
            if let f = n.sourceFile { fileNodeID[f] = n.id }
        }
        let codeFiles = fileNodeID.keys.filter { codeExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        let slots = Slots<String>(count: codeFiles.count)
        DispatchQueue.concurrentPerform(iterations: codeFiles.count) { i in
            if let t = read(root.appendingPathComponent(codeFiles[i])) { slots.set(i, t) }
        }
        var texts: [String: String] = [:]
        for (i, f) in codeFiles.enumerated() { if let t = slots.value(i) { texts[f] = t } }

        tick("read")
        // "Which function makes this call": the innermost function whose
        // body contains the line (Spans), else the file itself.
        var functions: [String: [(line: Int, id: String)]] = [:]
        for n in graph.nodes where n.kind == .function || n.kind == .method {
            guard let f = n.sourceFile, let l = n.line, texts[f] != nil else { continue }
            functions[f, default: []].append((l, n.id))
        }
        // Inline route handlers (`r.get('/x', async (c) => { … })`) aren't
        // functions to graphify: their body belongs to the route itself, so
        // "GET /x reads users" — added to the spans once routes are known.
        var spans = Spans(functions: functions, texts: texts)
        func owner(_ file: String, _ line: Int) -> String? { spans.owner(file, line) ?? fileNodeID[file] }
        func fileNode(_ f: String) -> String {
            if let id = fileNodeID[f] { return id }
            let id = "mapo:file:\(f)"
            doc.nodes.append(.init(id: id, label: (f as NSString).lastPathComponent, type: "file", source_file: f, source_location: "L1"))
            fileNodeID[f] = id
            return id
        }

        tick("spans")
        // HTTP (JS/TS frameworks, Next.js, Cloudflare Workers, Python)
        // Test servers and fixtures aren't the app's surface.
        let routes = (findRoutes(texts: texts) + pythonRoutes(texts: texts)).filter { !MapPayload.isTestPath($0.file) }
        var routeID: [Int: String] = [:]
        var seen = Set<String>()
        for (i, r) in routes.enumerated() {
            let id = "mapo:route:\(r.method) \(r.path)"
            routeID[i] = id
            guard seen.insert(id).inserted, let fileID = fileNodeID[r.file] else { continue }
            doc.nodes.append(.init(id: id, label: "\(r.method) \(r.path)", type: "route", source_file: r.file, source_location: "L\(r.line)"))
            doc.links.append(.init(source: fileID, target: id, relation: "contains", confidence: "EXTRACTED", source_file: r.file, source_location: "L\(r.line)"))
            out.routes += 1
        }
        var handlers = functions
        for (i, r) in routes.enumerated() where routeID[i] != nil && texts[r.file] != nil {
            handlers[r.file, default: []].append((r.line, routeID[i]!))
        }
        spans = Spans(functions: handlers, texts: texts)
        // Calls made inside an inline handler belong to its route: graphify
        // sees only the file's imports there, so "POST /orders → saveOrder"
        // is read from the handler's text, against names the file imports or
        // defines (nothing else can be called by that name).
        var callable: [String: [String: String]] = [:]   // file → name → node id
        for e in graph.edges where e.relation.isImport {
            let src = graph.nodes[e.sourcePosition], dst = graph.nodes[e.targetPosition]
            guard src.kind == .file, let f = src.sourceFile, [.function, .method, .type].contains(dst.kind) else { continue }
            callable[f, default: [:]][dst.name] = dst.id
        }
        for (f, list) in functions {
            for fn in list { if let n = graph.node(fn.id) { callable[f, default: [:]][n.name] = n.id } }
        }
        for (i, r) in routes.enumerated() {
            guard let id = routeID[i], let span = spans.range(r.file, id), let names = callable[r.file], let text = texts[r.file] else { continue }
            let lines = text.components(separatedBy: "\n")
            guard span.upperBound <= lines.count else { continue }
            var seenCalls = Set<String>()
            for ln in span {
                let line = lines[ln - 1]
                for m in callName.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let r = Range(m.range(at: 1), in: line), let target = names[String(line[r])],
                          spans.owner(routes[i].file, ln) == id,
                          seenCalls.insert(target).inserted else { continue }
                    doc.links.append(.init(source: id, target: target, relation: "calls", confidence: "INFERRED", source_file: routes[i].file, source_location: "L\(ln)"))
                }
            }
        }
        var edges = Set<String>()
        func request(_ from: String?, _ target: String, _ file: String, _ line: Int) {
            guard let from, edges.insert(from + "→" + target).inserted else { return }
            doc.links.append(.init(source: from, target: target, relation: "requests", confidence: "INFERRED", source_file: file, source_location: "L\(line)"))
            out.requests += 1
        }
        if !routes.isEmpty {
            let serverFiles = Set(routes.map(\.file))
            for call in findCalls(texts: texts, skipping: serverFiles) + pythonCalls(texts: texts) {
                guard let i = match(call, in: routes), let target = routeID[i], seen.contains(target) else { continue }
                request(owner(call.file, call.line), target, call.file, call.line)
            }
        }

        tick("http")
        // tRPC
        let procedures = findProcedures(texts: texts)
        if !procedures.isEmpty {
            var byPath: [String: String] = [:]
            for p in procedures {
                let id = "mapo:trpc:\(p.path)"
                guard byPath[p.path] == nil, let fileID = fileNodeID[p.file] else { continue }
                byPath[p.path] = id
                doc.nodes.append(.init(id: id, label: "tRPC \(p.path)", type: "route", source_file: p.file, source_location: "L\(p.line)"))
                doc.links.append(.init(source: fileID, target: id, relation: "contains", confidence: "EXTRACTED", source_file: p.file, source_location: "L\(p.line)"))
                out.routes += 1
            }
            for c in findRPCCalls(texts: texts) {
                guard let target = byPath[c.path] else { continue }
                request(owner(c.file, c.line), target, c.file, c.line)
            }
        }

        tick("trpc")
        // Databases (SQL migrations, Prisma, Drizzle; used via SQL, Supabase, Prisma, Drizzle)
        let tables = findTables(root: root, texts: texts, schemaFiles: findSchemaFiles(root: root))
        var tableID: [String: String] = [:]
        for t in tables {
            let id = "mapo:table:\(t.name.lowercased())"
            tableID[t.name] = id
            let fileID = fileNode(t.file)
            doc.nodes.append(.init(id: id, label: t.name, type: "table", source_file: t.file, source_location: "L\(t.line)"))
            doc.links.append(.init(source: fileID, target: id, relation: "contains", confidence: "EXTRACTED", source_file: t.file, source_location: "L\(t.line)"))
            out.tables += 1
        }
        if !tables.isEmpty {
            var used = Set<String>()
            for u in findTableUses(texts: texts, tables: tables) {
                guard let target = tableID[u.table], let from = owner(u.file, u.line) else { continue }
                let rel = u.writes ? "writes" : "reads"
                guard used.insert("\(from)→\(target)→\(rel)").inserted else { continue }
                doc.links.append(.init(source: from, target: target, relation: rel, confidence: "INFERRED", source_file: u.file, source_location: "L\(u.line)"))
                out.queries += 1
            }
        }
        return (doc, out)
    }

    /// `name(` — a call site (also matches `await name(`, `x = name(`).
    static let callName = try! NSRegularExpression(pattern: #"(?<![\w$.])([A-Za-z_$][\w$]*)\s*\("#)

    // MARK: - HTTP: server side

    static let codeExtensions: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts", "py"]

    static let serverMarker = try! NSRegularExpression(
        pattern: #"from\s+['"](hono|express|fastify|koa-router|@koa/router|itty-router|elysia)['"/]|require\(\s*['"](express|fastify|koa-router)['"]\s*\)|new\s+(Hono|Elysia|Router)\s*[<(]|\bexpress\.Router\s*\(|export\s+default\s*\{[^}]{0,400}?\bfetch\s*[(:]"#)

    /// Cloudflare Workers without a router: `if (url.pathname === '/x')`,
    /// `case '/x':` inside a module worker's fetch handler.
    static let workerPath = try! NSRegularExpression(
        pattern: #"pathname\s*===?\s*['"`](/[^'"`]*)['"`]|\bcase\s+['"`](/[^'"`]*)['"`]\s*:"#)

    static let routeDef = try! NSRegularExpression(
        pattern: #"\b([A-Za-z_$][\w$]*)\s*\.\s*(get|post|put|patch|delete|all|options|head)\s*(?:<[^>()]*>)?\s*\(\s*(['"`])(/[^'"`]*)\3\s*,"#)

    static let mount = try! NSRegularExpression(
        pattern: #"\b[A-Za-z_$][\w$]*\s*\.\s*(?:route|use|basePath|register)\s*\(\s*(['"`])(/[^'"`]*)\1\s*,\s*([A-Za-z_$][\w$]*)"#)

    static let importDefault = try! NSRegularExpression(pattern: #"import\s+([A-Za-z_$][\w$]*)\s*(?:,\s*\{[^}]*\})?\s+from\s+['"](\.[^'"]+)['"]"#)
    static let importNamed = try! NSRegularExpression(pattern: #"import\s*(?:[A-Za-z_$][\w$]*\s*,\s*)?\{([^}]*)\}\s*from\s+['"](\.[^'"]+)['"]"#)
    static let requireDefault = try! NSRegularExpression(pattern: #"(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*require\(\s*['"](\.[^'"]+)['"]\s*\)"#)

    static let nextExport = try! NSRegularExpression(pattern: #"export\s+(?:async\s+)?(?:function|const)\s+(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\b"#)

    static func findRoutes(texts: [String: String]) -> [Route] {
        var routes: [Route] = []
        var serverFiles: [String] = []
        for (f, t) in texts.sorted(by: { $0.key < $1.key }) {
            if serverMarker.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { serverFiles.append(f) }
        }
        let known = Set(texts.keys)

        // Mount prefixes: file → prefix, following nested mounts.
        var parent: [String: (from: String, prefix: String)] = [:]
        for f in serverFiles {
            guard let t = texts[f] else { continue }
            let imports = importMap(t, file: f, known: known)
            for m in mount.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                guard let p = Range(m.range(at: 2), in: t), let id = Range(m.range(at: 3), in: t),
                      let target = imports[String(t[id])], target != f else { continue }
                parent[target] = (f, String(t[p]))
            }
        }
        func prefix(of file: String) -> String {
            var parts: [String] = []
            var at = file
            var hops = 0
            while let p = parent[at], hops < 8 { parts.insert(p.prefix, at: 0); at = p.from; hops += 1 }
            return parts.joined()
        }

        for f in serverFiles {
            guard let t = texts[f] else { continue }
            let lines = LineIndex(t)
            let base = prefix(of: f)
            var found = false
            for m in routeDef.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                guard let mr = Range(m.range(at: 2), in: t), let pr = Range(m.range(at: 4), in: t) else { continue }
                let path = normalize(base + String(t[pr]))
                guard !path.contains("${") else { continue }
                routes.append(Route(method: t[mr].uppercased() == "ALL" ? "*" : t[mr].uppercased(), path: path, file: f, line: lines.line(at: m.range.location)))
                found = true
            }
            // A worker that routes by hand (no framework routes in the file).
            if !found {
                for m in workerPath.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                    let g = m.range(at: 1).location != NSNotFound ? 1 : 2
                    guard let pr = Range(m.range(at: g), in: t) else { continue }
                    routes.append(Route(method: "*", path: normalize(base + String(t[pr])), file: f, line: lines.line(at: m.range.location)))
                }
            }
        }

        // Next.js app router and pages/api.
        for (f, t) in texts {
            let parts = f.split(separator: "/").map(String.init)
            if let a = parts.lastIndex(of: "app"), parts.last?.hasPrefix("route.") == true {
                let path = nextPath(parts[(a + 1)..<(parts.count - 1)])
                let lines = LineIndex(t)
                for m in nextExport.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                    guard let r = Range(m.range(at: 1), in: t) else { continue }
                    routes.append(Route(method: String(t[r]), path: path, file: f, line: lines.line(at: m.range.location)))
                }
            } else if let p = parts.lastIndex(of: "pages"), p + 1 < parts.count, parts[p + 1] == "api" {
                var segs = Array(parts[(p + 1)...])
                segs[segs.count - 1] = (segs[segs.count - 1] as NSString).deletingPathExtension
                if segs.last == "index" { segs.removeLast() }
                routes.append(Route(method: "*", path: nextPath(segs[...]), file: f, line: 1))
            }
        }
        return routes
    }

    static func nextPath(_ segments: ArraySlice<String>) -> String {
        let segs = segments.compactMap { s -> String? in
            if s.hasPrefix("(") && s.hasSuffix(")") { return nil }
            if s.hasPrefix("@") { return nil }
            if s.hasPrefix("[") && s.hasSuffix("]") {
                let inner = s.dropFirst().dropLast().replacingOccurrences(of: "...", with: "")
                return ":" + inner.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            }
            return s
        }
        return "/" + segs.joined(separator: "/")
    }

    /// Identifier → project file, for relative imports in `text`.
    static func importMap(_ text: String, file: String, known: Set<String>) -> [String: String] {
        var map: [String: String] = [:]
        let dir = (file as NSString).deletingLastPathComponent
        func resolve(_ spec: String) -> String? {
            let joined = ((dir as NSString).appendingPathComponent(spec) as NSString).standardizingPath
            let base = joined.hasPrefix("/") ? String(joined.dropFirst()) : joined
            let stripped = (base as NSString).deletingPathExtension
            for cand in [base] + codeExtensions.sorted().flatMap({ [stripped + "." + $0, base + "/index." + $0] }) where known.contains(cand) {
                return cand
            }
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        for re in [importDefault, requireDefault] {
            for m in re.matches(in: text, range: range) {
                guard let n = Range(m.range(at: 1), in: text), let s = Range(m.range(at: 2), in: text),
                      let target = resolve(String(text[s])) else { continue }
                map[String(text[n])] = target
            }
        }
        for m in importNamed.matches(in: text, range: range) {
            guard let list = Range(m.range(at: 1), in: text), let s = Range(m.range(at: 2), in: text),
                  let target = resolve(String(text[s])) else { continue }
            for item in text[list].split(separator: ",") {
                let words = item.split(whereSeparator: \.isWhitespace)
                if let local = words.last, !local.isEmpty { map[String(local)] = target }
            }
        }
        return map
    }

    // MARK: - HTTP: client side

    /// `get('/x')`, `axios.get(`${API}/x`)`, `env.AUTH.fetch('https://auth/x')`
    /// (Cloudflare service binding: a bare host name, or localhost, is ours).
    static let clientCall = try! NSRegularExpression(
        pattern: #"(?<![\w$.])((?:[A-Za-z_$][\w$]*\.){0,2}[A-Za-z_$][\w$]*)\s*(?:<[^>()]*>)?\s*\(\s*(['"`])((?:\$\{[^}]*\}|https?://(?:localhost|127\.0\.0\.1|[A-Za-z0-9_-]+)(?::\d+)?)?/[^'"`]*)\2"#)

    static let methodOption = try! NSRegularExpression(pattern: #"method\s*:\s*['"`](GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)['"`]"#, options: .caseInsensitive)

    static let clientNames: Set<String> = [
        "fetch", "$fetch", "ofetch", "usefetch", "useswr", "request", "api", "apifetch", "http", "client", "istek", "cagir",
        "get", "post", "put", "patch", "del", "delete", "axios", "ky", "got", "superagent",
    ]

    static func findCalls(texts: [String: String], skipping: Set<String>) -> [Call] {
        perFile(texts, where: { !skipping.contains($0) && !$0.hasSuffix(".py") }) { f, t in
            var calls: [Call] = []
            let lines = LineIndex(t)
            let ns = t as NSString
            for m in clientCall.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let callee = ns.substring(with: m.range(at: 1)).lowercased()
                let last = callee.split(separator: ".").last.map(String.init) ?? callee
                let head = callee.split(separator: ".").first.map(String.init) ?? callee
                guard clientNames.contains(last) || clientNames.contains(head) else { continue }
                let raw = ns.substring(with: m.range(at: 3))
                let path = normalize(raw)
                guard path.count > 1 else { continue }
                var method = "*"
                switch last {
                case "get", "post", "put", "patch": method = last.uppercased()
                case "del", "delete": method = "DELETE"
                case "fetch", "$fetch", "ofetch":
                    method = "GET"
                    // Only this call's own arguments: up to its closing paren.
                    let after = NSRange(location: m.range.location + m.range.length, length: argumentsLength(ns, from: m.range.location + m.range.length))
                    if let o = methodOption.firstMatch(in: t, range: after) { method = ns.substring(with: o.range(at: 1)).uppercased() }
                default: break
                }
                let parts = ns.substring(with: m.range(at: 1)).split(separator: ".")
                let receiver = parts.count > 1 ? String(parts[parts.count - 2]) : nil
                calls.append(Call(method: method, path: path, file: f, line: lines.line(at: m.range.location), receiver: receiver))
            }
            return calls
        }
    }

    /// UTF-16 length from `start` to the paren closing the call that opened
    /// just before it (capped), so options of the next call aren't read.
    static func argumentsLength(_ ns: NSString, from start: Int) -> Int {
        var depth = 1, i = start
        let end = min(ns.length, start + 800)
        while i < end {
            switch ns.character(at: i) {
            case 40: depth += 1          // (
            case 41: depth -= 1          // )
                if depth == 0 { return i - start }
            default: break
            }
            i += 1
        }
        return end - start
    }

    /// `${API}/api/kulup/${id}?x=1` → `/api/kulup/:p`; route params stay `:name`.
    /// A hole glued to text (`/kulup${sorgu}`) is a query suffix and is dropped;
    /// an unclosed one (nested template) ends the path.
    static func normalize(_ raw: String) -> String {
        var s = raw
        if let origin = s.range(of: #"^https?://[^/]+"#, options: .regularExpression) { s.removeSubrange(origin) }
        if s.hasPrefix("${"), let close = s.firstIndex(of: "}") { s = String(s[s.index(after: close)...]) }
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<q]) }
        while let open = s.range(of: "${") {
            guard let close = s[open.upperBound...].firstIndex(of: "}") else {
                s = String(s[..<open.lowerBound])
                break
            }
            let ownSegment = open.lowerBound == s.startIndex || s[s.index(before: open.lowerBound)] == "/"
            if ownSegment {
                s.replaceSubrange(open.lowerBound...close, with: ":p")
            } else {
                // Suffix hole: drop it and the rest of that segment's tail.
                let next = s[close...].firstIndex(of: "/") ?? s.endIndex
                s.removeSubrange(open.lowerBound..<next)
            }
        }
        while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Best route for a call: same segment count, literal segments equal,
    /// fewest parameters wins.
    static func match(_ call: Call, in routes: [Route]) -> Int? {
        let cs = call.path.split(separator: "/")
        var best: (Int, Int)?
        for (i, r) in routes.enumerated() {
            guard call.method == "*" || r.method == "*" || r.method == call.method else { continue }
            let rs = r.segments
            guard rs.count == cs.count else { continue }
            var params = 0, ok = true
            for (a, b) in zip(rs, cs) {
                if a.hasPrefix(":") || a == "*" { params += 1; continue }
                if b == ":p" { ok = false; break }
                if a != b { ok = false; break }
            }
            guard ok else { continue }
            if best == nil || params < best!.1 { best = (i, params) }
        }
        if let best { return best.0 }
        // Router-relative calls (`auth.request('/oauth/kayit')` in tests):
        // a unique route whose last segments match, starting with a literal;
        // `yonetim.request(…)` only looks in yonetim.ts.
        let own = call.receiver.map { rcv in routes.indices.filter { ((routes[$0].file as NSString).lastPathComponent as NSString).deletingPathExtension == rcv } } ?? []
        guard cs.first != ":p", cs.count >= 2 || !own.isEmpty else { return nil }
        let pool = own.isEmpty ? Array(routes.indices) : own
        let hits = pool.filter { i in
            let r = routes[i]
            guard call.method == "*" || r.method == "*" || r.method == call.method else { return false }
            let rs = r.segments
            guard rs.count > cs.count else { return false }
            let tail = rs.suffix(cs.count)
            guard tail.first == cs.first else { return false }
            return zip(tail, cs).allSatisfy { a, b in a == b || a.hasPrefix(":") || a == "*" }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    // MARK: - SQL

    static let createTable = try! NSRegularExpression(
        pattern: #"CREATE\s+(?:VIRTUAL\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[`"\[]?(?:\w+[`"\]]?\.[`"\[]?)?([A-Za-z_]\w*)"#, options: .caseInsensitive)

    /// Uppercase keywords only: `import x from "y"` must not read as SQL.
    /// `DELETE FROM x` writes even though it says FROM.
    static let sqlUse = try! NSRegularExpression(pattern: #"\b(DELETE\s+FROM|FROM|JOIN|INTO|UPDATE)\s+[`"]?([A-Za-z_]\w*)"#)

    static func findSchemaFiles(root: URL) -> [String] {
        let skip: Set<String> = ["node_modules", ".git", "build", "dist", ".next", "Pods", "DerivedData", ".build", "vendor"]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        let base = root.standardizedFileURL.path
        while let url = e.nextObject() as? URL {
            if skip.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            guard ["sql", "prisma"].contains(url.pathExtension.lowercased()) else { continue }
            let p = url.standardizedFileURL.path
            guard p.hasPrefix(base + "/") else { continue }
            out.append(String(p.dropFirst(base.count + 1)))
            if out.count >= 2000 { break }
        }
        return out.sorted()
    }

    // MARK: - Utilities

    static func read(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? Int ?? 0) < 2_000_000 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// UTF-16 offset → 1-based line.
    struct LineIndex {
        private var starts: [Int] = [0]
        init(_ text: String) {
            var i = 0
            for u in text.utf16 {
                i += 1
                if u == 10 { starts.append(i) }
            }
        }
        func line(at offset: Int) -> Int {
            var lo = 0, hi = starts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo + 1
        }
    }
}
