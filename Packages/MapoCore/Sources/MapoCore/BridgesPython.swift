import Foundation

/// Python web frameworks and HTTP clients.
///
/// - FastAPI: `@app.get("/x/{id}")`, `APIRouter(prefix="/api")`,
///   `app.include_router(users.router, prefix="/v1")`
/// - Flask: `@app.route("/x/<int:id>", methods=["POST"])`, `Blueprint(…, url_prefix="/api")`,
///   `app.register_blueprint(bp, url_prefix=…)`
/// - Django: `path("users/<int:pk>/", view)` and `include("app.urls")` in urls.py
/// - Clients: `requests` / `httpx` / sessions with `f"{BASE}/x/{id}"` strings
extension Bridges {
    static let pyDecorator = try! NSRegularExpression(
        pattern: #"(?m)^\s*@([A-Za-z_]\w*)\.(get|post|put|patch|delete|head|options|route|api_route)\(\s*[rbf]?["']([^"']*)["']([^\n]*)"#)
    static let pyRouterDef = try! NSRegularExpression(
        pattern: #"(?m)^\s*([A-Za-z_]\w*)\s*=\s*(?:fastapi\.)?(APIRouter|Blueprint|Flask|FastAPI)\(([^)]*)\)"#)
    static let pyPrefixArg = try! NSRegularExpression(pattern: #"(?:prefix|url_prefix)\s*=\s*["']([^"']*)["']"#)
    static let pyInclude = try! NSRegularExpression(
        pattern: #"\.(?:include_router|register_blueprint)\(\s*([A-Za-z_][\w.]*)\s*(?:,([^)]*))?\)"#)
    static let pyFromImport = try! NSRegularExpression(pattern: #"(?m)^\s*from\s+([.\w]+)\s+import\s+([^\n#]+)"#)
    static let pyMethods = try! NSRegularExpression(pattern: #"methods\s*=\s*\[([^\]]*)\]"#)
    static let djangoPath = try! NSRegularExpression(pattern: #"\b(?:re_)?path\(\s*r?["']([^"']*)["']\s*,\s*(include\(\s*["']([\w.]+)["'][^)]*\)|[\w.]+)"#)
    static let pyClient = try! NSRegularExpression(
        pattern: #"\b(requests|httpx|session|client|self\.client|self\.session|s|c)\s*\.\s*(get|post|put|patch|delete|request)\(\s*(?:["'](?:GET|POST|PUT|PATCH|DELETE)["']\s*,\s*)?([rbf]?)["']([^"']*)["']"#)

    static func pythonRoutes(texts: [String: String]) -> [Route] {
        let py = texts.filter { $0.key.hasSuffix(".py") }
        guard !py.isEmpty else { return [] }
        let known = Set(py.keys)

        // Router variable prefixes within each file, and cross-file includes.
        var localPrefix: [String: [String: String]] = [:]   // file → var → prefix
        var mountedPrefix: [String: String] = [:]            // file → prefix it's mounted at
        for (f, t) in py {
            let ns = t as NSString
            for m in pyRouterDef.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let args = ns.substring(with: m.range(at: 3))
                let p = pyPrefixArg.firstMatch(in: args, range: NSRange(args.startIndex..., in: args)).flatMap { Range($0.range(at: 1), in: args) }.map { String(args[$0]) } ?? ""
                localPrefix[f, default: [:]][ns.substring(with: m.range(at: 1))] = p
            }
        }
        for (f, t) in py {
            let ns = t as NSString
            let imports = pythonImports(t, file: f, known: known)
            for m in pyInclude.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let target = ns.substring(with: m.range(at: 1))
                let args = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
                let p = pyPrefixArg.firstMatch(in: args, range: NSRange(args.startIndex..., in: args)).flatMap { Range($0.range(at: 1), in: args) }.map { String(args[$0]) } ?? ""
                let head = String(target.split(separator: ".").first ?? "")
                if let file = imports[head], file != f { mountedPrefix[file] = (mountedPrefix[file] ?? "") + p }
            }
        }

        var routes: [Route] = []
        for (f, t) in py.sorted(by: { $0.key < $1.key }) {
            let ns = t as NSString
            let lines = LineIndex(t)
            for m in pyDecorator.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let owner = ns.substring(with: m.range(at: 1))
                let verb = ns.substring(with: m.range(at: 2))
                let rest = ns.substring(with: m.range(at: 4))
                guard let routerPrefix = localPrefix[f]?[owner] ?? (["app", "router", "api", "bp", "blueprint"].contains(owner) ? "" : nil) else { continue }
                var methods = [verb.uppercased()]
                if verb == "route" || verb == "api_route" {
                    let found = pyMethods.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)).flatMap { Range($0.range(at: 1), in: rest) }
                        .map { rest[$0].uppercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty } } ?? []
                    methods = found.isEmpty ? ["GET"] : found
                }
                let path = normalize(pythonPath((mountedPrefix[f] ?? "") + routerPrefix + ns.substring(with: m.range(at: 3))))
                for method in methods { routes.append(Route(method: method, path: path, file: f, line: lines.line(at: m.range.location))) }
            }
        }

        // Django: urls.py files, following include("x.urls") one level at a time.
        let urlFiles = py.keys.filter { $0.hasSuffix("urls.py") }
        var djangoPrefix: [String: String] = [:]
        var changed = true, rounds = 0
        while changed && rounds < 5 {
            changed = false
            rounds += 1
            for f in urlFiles {
                guard let t = py[f] else { continue }
                let ns = t as NSString
                for m in djangoPath.matches(in: t, range: NSRange(location: 0, length: ns.length)) where m.range(at: 3).location != NSNotFound {
                    let module = ns.substring(with: m.range(at: 3))
                    guard let target = moduleFile(module, known: known), target != f else { continue }
                    let p = (djangoPrefix[f] ?? "") + "/" + ns.substring(with: m.range(at: 1))
                    if djangoPrefix[target] != p { djangoPrefix[target] = p; changed = true }
                }
            }
        }
        for f in urlFiles.sorted() {
            guard let t = py[f] else { continue }
            let ns = t as NSString
            let lines = LineIndex(t)
            for m in djangoPath.matches(in: t, range: NSRange(location: 0, length: ns.length)) where m.range(at: 3).location == NSNotFound {
                let path = normalize(pythonPath((djangoPrefix[f] ?? "") + "/" + ns.substring(with: m.range(at: 1))))
                routes.append(Route(method: "*", path: path, file: f, line: lines.line(at: m.range.location)))
            }
        }
        return routes
    }

    /// `{id}` / `<int:id>` → `:id`; Django regexes are left alone (rare).
    static func pythonPath(_ p: String) -> String {
        var s = p
        s = s.replacingOccurrences(of: #"\{([A-Za-z_]\w*)(?::[^}]*)?\}"#, with: ":$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<(?:[a-z]+:)?([A-Za-z_]\w*)>"#, with: ":$1", options: .regularExpression)
        return s.hasPrefix("/") ? s : "/" + s
    }

    /// Imported name → project file (`from app.routers import users`,
    /// `from .users import router as users_router`).
    static func pythonImports(_ text: String, file: String, known: Set<String>) -> [String: String] {
        var map: [String: String] = [:]
        let ns = text as NSString
        let pkg = (file as NSString).deletingLastPathComponent
        for m in pyFromImport.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var module = ns.substring(with: m.range(at: 1))
            var base = ""
            if module.hasPrefix(".") {
                let dots = module.prefix { $0 == "." }.count
                var dir = pkg
                for _ in 1..<max(dots, 1) { dir = (dir as NSString).deletingLastPathComponent }
                module = String(module.dropFirst(dots))
                base = dir
            }
            for item in ns.substring(with: m.range(at: 2)).replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "").split(separator: ",") {
                let words = item.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let name = words.first else { continue }
                let local = words.count == 3 && words[1] == "as" ? words[2] : name
                let asModule = module.isEmpty ? name : module + "." + name
                if let f = moduleFile(asModule, known: known, base: base) ?? moduleFile(module, known: known, base: base) {
                    map[local] = f
                }
            }
        }
        return map
    }

    static func moduleFile(_ module: String, known: Set<String>, base: String = "") -> String? {
        guard !module.isEmpty else { return nil }
        let rel = module.replacingOccurrences(of: ".", with: "/")
        let stem = base.isEmpty ? rel : base + "/" + rel
        for cand in [stem + ".py", stem + "/__init__.py"] where known.contains(cand) { return cand }
        // Absolute imports from a source root (src/, app/…): match by suffix.
        guard base.isEmpty else { return nil }
        return known.first { $0.hasSuffix("/" + rel + ".py") } ?? known.first { $0.hasSuffix("/" + rel + "/__init__.py") }
    }

    static func pythonCalls(texts: [String: String]) -> [Call] {
        perFile(texts, where: { $0.hasSuffix(".py") }) { f, t in
            var calls: [Call] = []
            let ns = t as NSString
            let lines = LineIndex(t)
            for m in pyClient.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let verb = ns.substring(with: m.range(at: 2))
                let isF = ns.substring(with: m.range(at: 3)).contains("f")
                var raw = ns.substring(with: m.range(at: 4))
                // Absolute URLs to the local dev server or a bare service name.
                if let r = raw.range(of: #"^https?://(?:localhost|127\.0\.0\.1|[A-Za-z0-9_-]+)(?::\d+)?"#, options: .regularExpression) { raw.removeSubrange(r) }
                if isF {
                    // f"{BASE}/x/{id}" → "${BASE}/x/${id}" for the shared normaliser.
                    raw = raw.replacingOccurrences(of: #"\{([^{}]*)\}"#, with: "\\${$1}", options: .regularExpression)
                }
                guard raw.hasPrefix("/") || raw.hasPrefix("${") else { continue }
                let path = normalize(raw)
                guard path.count > 1 else { continue }
                let method = verb == "request" ? "*" : verb.uppercased()
                calls.append(Call(method: method, path: path, file: f, line: lines.line(at: m.range.location)))
            }
            return calls
        }
    }
}
