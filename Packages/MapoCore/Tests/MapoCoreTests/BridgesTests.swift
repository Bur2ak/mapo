import Foundation
import Testing
@testable import MapoCore

@Suite("Köprüler (HTTP + SQL)")
struct BridgesTests {
    /// Writes `files` under a temp root and builds a graph with one file node
    /// per code file and the given functions (file, name, line).
    private func project(_ files: [String: String], functions: [(String, String, Int)] = []) throws -> (URL, Graph) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-bridges-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        var nodes: [Node] = []
        var edges: [Edge] = []
        for path in files.keys where !path.hasSuffix(".sql") {
            nodes.append(Node(id: "f:" + path, label: (path as NSString).lastPathComponent, kind: .file, sourceFile: path, line: 1, community: nil))
        }
        for (file, name, line) in functions {
            nodes.append(Node(id: "fn:\(file):\(name)", label: name + "()", kind: .function, sourceFile: file, line: line, community: nil))
            edges.append(Edge(source: "f:" + file, target: "fn:\(file):\(name)", relation: .contains, confidence: .extracted, sourceFile: file, line: line))
        }
        return (root, Graph(nodes: nodes, edges: edges))
    }

    private func links(_ doc: Bridges.Doc, _ relation: String) -> [(String, String)] {
        doc.links.filter { $0.relation == relation }.map { ($0.source, $0.target) }
    }

    @Test func honoMountsAndClientCalls() throws {
        let (root, graph) = try project([
            "api/src/index.ts": """
            import { Hono } from 'hono'
            import kulup from './routes/kulup'
            const app = new Hono()
            app.route('/api/kulup', kulup)
            app.get('/api/saglik', (c) => c.text('ok'))
            """,
            "api/src/routes/kulup.ts": """
            import { Hono } from 'hono'
            const kulup = new Hono()
            kulup.get('/:id', async (c) => c.json({}))
            kulup.post('/:id/katil', async (c) => c.json({}))
            export default kulup
            """,
            "mobile/lib/api.ts": """
            export async function kulupGetir(id: string) {
              return get<Kulup>(`/api/kulup/${id}`)
            }
            export async function katil(id: string) {
              return post(`/api/kulup/${encodeURIComponent(id)}/katil`, {})
            }
            export async function saglik() {
              const r = await fetch(`${API_URL}/api/saglik?x=1`)
            }
            export async function yanlis() {
              return post('/api/kulup/123') // POST /:id yok → bağ yok
            }
            """,
        ], functions: [("mobile/lib/api.ts", "kulupGetir", 1), ("mobile/lib/api.ts", "katil", 4), ("mobile/lib/api.ts", "saglik", 7), ("mobile/lib/api.ts", "yanlis", 10)])
        let (doc, out) = Bridges.extract(root: root, graph: graph)
        let routes = Set(doc.nodes.filter { $0.type == "route" }.map(\.label))
        #expect(routes == ["GET /api/kulup/:id", "POST /api/kulup/:id/katil", "GET /api/saglik"])
        let req = links(doc, "requests").map { "\($0.0)→\($0.1)" }
        #expect(Set(req) == [
            "fn:mobile/lib/api.ts:kulupGetir→mapo:route:GET /api/kulup/:id",
            "fn:mobile/lib/api.ts:katil→mapo:route:POST /api/kulup/:id/katil",
            "fn:mobile/lib/api.ts:saglik→mapo:route:GET /api/saglik",
        ])
        #expect(out.routes == 3 && out.requests == 3)
        // Routes live inside the file that defines them.
        #expect(links(doc, "contains").contains { $0 == ("f:api/src/routes/kulup.ts", "mapo:route:GET /api/kulup/:id") })
    }

    @Test func expressUseAndFetchMethod() throws {
        let (root, graph) = try project([
            "server/app.js": """
            const express = require('express')
            const users = require('./users')
            const app = express()
            app.use('/v1/users', users)
            """,
            "server/users.js": """
            const router = express.Router()
            router.delete('/:id', (req, res) => res.end())
            module.exports = router
            """,
            "web/sil.ts": """
            export function sil(id) {
              return fetch(`/v1/users/${id}`, { method: 'DELETE' })
            }
            export function oku(id) {
              const a = await fetch(`/v1/users/${id}`, { headers: h })
              const b = await fetch('/v1/other', { method: 'DELETE' })
            }
            """,
        ], functions: [("web/sil.ts", "sil", 1), ("web/sil.ts", "oku", 4)])
        let (doc, _) = Bridges.extract(root: root, graph: graph)
        #expect(doc.nodes.contains { $0.label == "DELETE /v1/users/:id" })
        let req = links(doc, "requests")
        #expect(req.count == 1 && req[0].0 == "fn:web/sil.ts:sil")  // GET doesn't match DELETE
    }

    @Test func nextAppRouter() throws {
        let (root, graph) = try project([
            "src/app/api/(public)/posts/[slug]/route.ts": "export async function GET(req) {}\nexport const POST = async () => {}",
            "src/app/page.tsx": "export default async function Page() { await fetch('/api/posts/merhaba') }",
        ], functions: [("src/app/page.tsx", "Page", 1)])
        let (doc, _) = Bridges.extract(root: root, graph: graph)
        #expect(Set(doc.nodes.filter { $0.type == "route" }.map(\.label)) == ["GET /api/posts/:slug", "POST /api/posts/:slug"])
        #expect(links(doc, "requests").map(\.1) == ["mapo:route:GET /api/posts/:slug"])
    }

    @Test func sqlTablesAndQueries() throws {
        let (root, graph) = try project([
            "api/migrations/0001_baslangic.sql": """
            CREATE TABLE kullanicilar (id TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS "kulupler" (id TEXT);
            """,
            "api/migrations/0002.sql": "ALTER TABLE kulupler ADD COLUMN ad TEXT;",
            "api/src/db.ts": """
            import { x } from "kulupler"
            export async function kullaniciBul(db, id) {
              return db.prepare('SELECT * FROM kullanicilar WHERE id = ?').bind(id).first()
            }
            export async function kulupEkle(db) {
              await db.prepare(`INSERT INTO kulupler (id) VALUES (?)`).run()
              await db.prepare(`SELECT k.* FROM kulupler k JOIN kullanicilar u ON 1`).all()
            }
            export async function sil(db) {
              await db.prepare('DELETE FROM kullanicilar WHERE id = ?').run()
            }
            """,
        ], functions: [("api/src/db.ts", "kullaniciBul", 2), ("api/src/db.ts", "kulupEkle", 5), ("api/src/db.ts", "sil", 9)])
        let (doc, out) = Bridges.extract(root: root, graph: graph)
        #expect(Set(doc.nodes.filter { $0.type == "table" }.map(\.label)) == ["kullanicilar", "kulupler"])
        // The migration file becomes a file node (graphify skips .sql).
        #expect(doc.nodes.contains { $0.type == "file" && $0.source_file == "api/migrations/0001_baslangic.sql" })
        #expect(!doc.nodes.contains { $0.source_file == "api/migrations/0002.sql" })
        let reads = Set(links(doc, "reads").map { "\($0.0)→\($0.1)" })
        let writes = Set(links(doc, "writes").map { "\($0.0)→\($0.1)" })
        #expect(reads == [
            "fn:api/src/db.ts:kullaniciBul→mapo:table:kullanicilar",
            "fn:api/src/db.ts:kulupEkle→mapo:table:kulupler",
            "fn:api/src/db.ts:kulupEkle→mapo:table:kullanicilar",
        ])
        #expect(writes == ["fn:api/src/db.ts:kulupEkle→mapo:table:kulupler", "fn:api/src/db.ts:sil→mapo:table:kullanicilar"])
        #expect(out.tables == 2 && out.queries == 5)
    }

    @Test func noServerNoBridgesAndLoaderMerges() throws {
        let (root, graph) = try project(["web/a.ts": "export const x = fetch('/api/y')"])
        let dir = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(Bridges.write(root: root, graph: graph, graphDir: dir) == Bridges.Output())
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(Bridges.fileName).path))

        // Merge: a bridges file beside graph.json adds its nodes and edges.
        let graphJSON = #"{"nodes":[{"id":"f","label":"a.ts","source_file":"web/a.ts"}],"links":[]}"#
        let bridges = #"{"nodes":[{"id":"mapo:route:GET /x","label":"GET /x","type":"route","source_file":"web/a.ts","source_location":"L1"}],"links":[{"source":"f","target":"mapo:route:GET /x","relation":"contains","confidence":"EXTRACTED"}]}"#
        try Data(graphJSON.utf8).write(to: dir.appendingPathComponent("graph.json"))
        try Data(bridges.utf8).write(to: dir.appendingPathComponent(Bridges.fileName))
        let (g, _) = try GraphLoader.load(from: dir.appendingPathComponent("graph.json"))
        #expect(g.node("mapo:route:GET /x")?.kind == .route)
        #expect(g.edges.count == 1)
        // A corrupt bridges file is ignored.
        try Data("{".utf8).write(to: dir.appendingPathComponent(Bridges.fileName))
        #expect(try GraphLoader.load(from: dir.appendingPathComponent("graph.json")).0.nodes.count == 1)
    }

    @Test func normalizeAndMatch() {
        #expect(Bridges.normalize("${API_URL}/api/kulup/${id}/uye?x=1") == "/api/kulup/:p/uye")
        #expect(Bridges.normalize("/api//a/") == "/api/a")
        #expect(Bridges.normalize("/api/kulup${s}") == "/api/kulup")
        #expect(Bridges.normalize("/api/kulup/${id}/mesajlar${once ? ") == "/api/kulup/:p/mesajlar")
        #expect(Bridges.normalize("/api/geri-al${kanal ? ") == "/api/geri-al")
        let routes = [
            Bridges.Route(method: "GET", path: "/a/:id", file: "s", line: 1),
            Bridges.Route(method: "GET", path: "/a/yeni", file: "s", line: 2),
        ]
        // Literal beats parameter.
        #expect(Bridges.match(.init(method: "GET", path: "/a/yeni", file: "c", line: 1), in: routes) == 1)
        #expect(Bridges.match(.init(method: "GET", path: "/a/:p", file: "c", line: 1), in: routes) == 0)
        #expect(Bridges.match(.init(method: "POST", path: "/a/:p", file: "c", line: 1), in: routes) == nil)
        // Router-relative suffix, only when unique.
        let mounted = [
            Bridges.Route(method: "POST", path: "/api/auth/oauth/kayit", file: "s", line: 1),
            Bridges.Route(method: "POST", path: "/api/auth/telefon/kod", file: "s", line: 2),
            Bridges.Route(method: "POST", path: "/api/kulup/telefon/kod", file: "s", line: 3),
        ]
        #expect(Bridges.match(.init(method: "POST", path: "/oauth/kayit", file: "c", line: 1), in: mounted) == 0)
        #expect(Bridges.match(.init(method: "POST", path: "/telefon/kod", file: "c", line: 1), in: mounted) == nil)
        #expect(Bridges.match(.init(method: "POST", path: "/kayit", file: "c", line: 1), in: mounted) == nil)
        let admin = [Bridges.Route(method: "GET", path: "/api/yonetim/kullanici/:id", file: "s", line: 1)]
        #expect(Bridges.match(.init(method: "*", path: "/kullanici/u1", file: "c", line: 1), in: admin) == 0)
        #expect(Bridges.match(.init(method: "*", path: "/:p/u1", file: "c", line: 1), in: admin) == nil)
        let two = [
            Bridges.Route(method: "GET", path: "/api/yonetim/kullanici/:id", file: "routes/yonetim.ts", line: 1),
            Bridges.Route(method: "GET", path: "/api/moderasyon/kullanici/:id", file: "routes/moderasyon.ts", line: 1),
            Bridges.Route(method: "GET", path: "/api/yonetim/kullanicilar", file: "routes/yonetim.ts", line: 2),
        ]
        #expect(Bridges.match(.init(method: "*", path: "/kullanici/u1", file: "c", line: 1), in: two) == nil)
        #expect(Bridges.match(.init(method: "*", path: "/kullanici/u1", file: "c", line: 1, receiver: "yonetim"), in: two) == 0)
        #expect(Bridges.match(.init(method: "*", path: "/kullanicilar", file: "c", line: 1, receiver: "yonetim"), in: two) == 2)
        #expect(Bridges.match(.init(method: "*", path: "/kullanicilar", file: "c", line: 1, receiver: "axios"), in: two) == nil)
    }

    /// Real-world smoke run: `MAPO_BRIDGES_ROOT=… MAPO_BRIDGES_GRAPH=…/graph.json swift test --filter realProject`
    @Test func realProject() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["MAPO_BRIDGES_ROOT"], let graphPath = env["MAPO_BRIDGES_GRAPH"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: graphPath))
        let (graph, _) = try GraphLoader.decode(data)
        let start = Date()
        let (doc, out) = Bridges.extract(root: URL(fileURLWithPath: root), graph: graph)
        if env["MAPO_BRIDGES_WRITE"] != nil {
            Bridges.write(root: URL(fileURLWithPath: root), graph: graph, graphDir: URL(fileURLWithPath: graphPath).deletingLastPathComponent())
        }
        print("BRIDGES routes=\(out.routes) requests=\(out.requests) tables=\(out.tables) queries=\(out.queries) in \(Date().timeIntervalSince(start))s")
        for l in doc.links.filter({ $0.relation == "requests" }).prefix(12) { print("  REQ", l.source, "→", l.target) }
        for l in doc.links.filter({ $0.relation != "requests" && $0.relation != "contains" }).prefix(8) { print("  SQL", l.relation, l.source, "→", l.target) }
        // What clients ask for that no route answers (coverage check).
        var texts: [String: String] = [:]
        for n in graph.nodes where n.kind == .file {
            if let f = n.sourceFile, let t = Bridges.read(URL(fileURLWithPath: root).appendingPathComponent(f)) { texts[f] = t }
        }
        let routes = Bridges.findRoutes(texts: texts)
        let calls = Bridges.findCalls(texts: texts, skipping: Set(routes.map(\.file)))
        let missed = calls.filter { Bridges.match($0, in: routes) == nil }
        print("CALLS \(calls.count) matched \(calls.count - missed.count)")
        let procs = Bridges.findProcedures(texts: texts)
        print("TRPC procedures \(procs.count)", procs.prefix(5).map(\.path))
        let rpc = Bridges.findRPCCalls(texts: texts)
        print("TRPC calls \(rpc.count)", rpc.prefix(5).map(\.path))
        if let app = texts.first(where: { $0.key.hasSuffix("routers/viewer/_router.tsx") }) {
            let ns = app.value as NSString
            for m in Bridges.trpcRouter.matches(in: app.value, range: NSRange(location: 0, length: ns.length)) {
                let e = Bridges.topLevelEntries(ns, openBrace: m.range.location + m.range.length - 1)
                print("VIEWER entries", e.count, e.prefix(4).map { "\($0.0)=\($0.1.prefix(40))" })
            }
        }
        let fileIDs = Set(graph.nodes.filter { $0.kind == .file }.map(\.id))
        let sqlEdges = doc.links.filter { $0.relation == "reads" || $0.relation == "writes" }
        print("SQL edges from files \(sqlEdges.filter { fileIDs.contains($0.source) || $0.source.hasPrefix("mapo:file:") }.count) / \(sqlEdges.count)")
        // Functions with a one-line span although their text spans more (brace parse failures).
        var fns: [String: [(line: Int, id: String)]] = [:]
        for n in graph.nodes where (n.kind == .function || n.kind == .method) {
            if let f = n.sourceFile, let l = n.line, texts[f] != nil { fns[f, default: []].append((l, n.id)) }
        }
        var oneLine = 0, total = 0
        for (f, list) in fns {
            let lines = texts[f]!.components(separatedBy: "\n")
            for x in list {
                total += 1
                let end = f.hasSuffix(".py") ? Bridges.Spans.pythonEnd(lines, start: x.line) : Bridges.Spans.braceEnd(lines, start: x.line)
                if end == x.line { oneLine += 1; if oneLine <= 6 { print("  ONE", f, x.line, lines[x.line - 1].prefix(90)) } }
            }
        }
        print("one-line spans \(oneLine) / \(total)")
        var byDir: [String: Int] = [:]
        for e in sqlEdges where fileIDs.contains(e.source) { byDir[(e.source_file as NSString).deletingLastPathComponent, default: 0] += 1 }
        for (d, c) in byDir.sorted(by: { $0.value > $1.value }).prefix(6) { print("  FILEDIR", d, c) }
        let routeSQL = sqlEdges.filter { $0.source.hasPrefix("mapo:route:") }
        print("SQL edges from routes \(routeSQL.count)"); for e in routeSQL.prefix(3) { print("  RT", e.source, e.relation, e.target) }
        for c in missed.prefix(40) { print("  MISS", c.method, c.path, c.file, c.line) }
    }
}
