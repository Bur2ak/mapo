import Foundation
import Testing
@testable import MapoCore

@Suite("Köprüler: ORM, tRPC, Python, Cloudflare")
struct BridgesMoreTests {
    private func project(_ files: [String: String], functions: [(String, String, Int)] = []) throws -> (URL, Graph) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-bridges2-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        var nodes: [Node] = []
        for path in files.keys where !path.hasSuffix(".sql") && !path.hasSuffix(".prisma") {
            nodes.append(Node(id: "f:" + path, label: (path as NSString).lastPathComponent, kind: .file, sourceFile: path, line: 1, community: nil))
        }
        for (file, name, line) in functions {
            nodes.append(Node(id: "fn:\(name)", label: name + "()", kind: .function, sourceFile: file, line: line, community: nil))
        }
        return (root, Graph(nodes: nodes, edges: []))
    }

    private func edges(_ doc: Bridges.Doc, _ rel: String) -> Set<String> {
        Set(doc.links.filter { $0.relation == rel }.map { "\($0.source)→\($0.target)" })
    }

    @Test func supabaseAgainstMigrations() throws {
        let (root, g) = try project([
            "supabase/migrations/001.sql": "create table public.profiles (id uuid);\ncreate table posts (id int);",
            "app/lib/data.ts": """
            export async function profilim(id) {
              const { data } = await supabase.from('profiles').select('*').eq('id', id)
              return data
            }
            export async function yaz(p) {
              await supabase
                .from('posts')
                .insert(p)
              await supabase.storage.from('avatars').upload('x', f)  // bucket, not a table
            }
            """,
        ], functions: [("app/lib/data.ts", "profilim", 1), ("app/lib/data.ts", "yaz", 5)])
        let (doc, _) = Bridges.extract(root: root, graph: g)
        #expect(edges(doc, "reads") == ["fn:profilim→mapo:table:profiles"])
        #expect(edges(doc, "writes") == ["fn:yaz→mapo:table:posts"])
    }

    @Test func prismaModelsAndClient() throws {
        let (root, g) = try project([
            "prisma/schema.prisma": """
            model User {
              id Int @id
              @@map("users")
            }
            model Post {
              id Int @id
            }
            """,
            "src/users.ts": """
            export async function list() { return prisma.user.findMany() }
            export async function make(d) {
              return db.post.create({ data: d })
            }
            export function unrelated() { return cache.thing.findMany() }
            """,
        ], functions: [("src/users.ts", "list", 1), ("src/users.ts", "make", 2), ("src/users.ts", "unrelated", 5)])
        let (doc, out) = Bridges.extract(root: root, graph: g)
        #expect(Set(doc.nodes.filter { $0.type == "table" }.map(\.label)) == ["users", "Post"])
        #expect(doc.nodes.contains { $0.type == "file" && $0.source_file == "prisma/schema.prisma" })
        #expect(edges(doc, "reads") == ["fn:list→mapo:table:users"])
        #expect(edges(doc, "writes") == ["fn:make→mapo:table:post"])
        #expect(out.queries == 2)
    }

    @Test func drizzleSchemaAndQueries() throws {
        let (root, g) = try project([
            "src/db/schema.ts": "export const users = pgTable('users', { id: serial('id') })\nexport const posts = sqliteTable(\"posts\", {})",
            "src/q.ts": """
            export async function feed() {
              return db.select().from(posts).leftJoin(users, eq(posts.uid, users.id))
            }
            export async function add(u) { await db.insert(users).values(u) }
            export function copy(users) { return Array.from(users) }
            export async function rel() { return db.query.posts.findMany() }
            """,
        ], functions: [("src/q.ts", "feed", 1), ("src/q.ts", "add", 4), ("src/q.ts", "copy", 5), ("src/q.ts", "rel", 6)])
        let (doc, _) = Bridges.extract(root: root, graph: g)
        // Tables live inside the schema file.
        #expect(doc.links.contains { $0.relation == "contains" && $0.source == "f:src/db/schema.ts" && $0.target == "mapo:table:users" })
        #expect(edges(doc, "reads") == ["fn:feed→mapo:table:posts", "fn:feed→mapo:table:users", "fn:rel→mapo:table:posts"])
        #expect(edges(doc, "writes") == ["fn:add→mapo:table:users"])
    }

    @Test func trpcNestedRouters() throws {
        let (root, g) = try project([
            "server/routers/user.ts": """
            export const userRouter = createTRPCRouter({
              byId: publicProcedure.input(z.string()).query(({ input }) => {
                return { id: input, tags: [1, 2] }
              }),
              rename: protectedProcedure.mutation(async () => {}),
            })
            """,
            "server/root.ts": "export const appRouter = createTRPCRouter({ user: userRouter, health: publicProcedure.query(() => 'ok') })",
            "app/page.tsx": """
            export function Profile() {
              const u = api.user.byId.useQuery('1')
              const m = trpc.user.rename.useMutation()
              const x = api.user.nope.useQuery()
            }
            """,
        ], functions: [("app/page.tsx", "Profile", 1)])
        let (doc, _) = Bridges.extract(root: root, graph: g)
        #expect(Set(doc.nodes.filter { $0.id.hasPrefix("mapo:trpc:") }.map(\.label)) == ["tRPC user.byId", "tRPC user.rename", "tRPC health"])
        #expect(edges(doc, "requests") == ["fn:Profile→mapo:trpc:user.byId", "fn:Profile→mapo:trpc:user.rename"])
    }

    @Test func fastapiFlaskDjangoAndClients() throws {
        let (root, g) = try project([
            "app/main.py": """
            from fastapi import FastAPI
            from app.routers import users
            app = FastAPI()
            app.include_router(users.router, prefix="/api")
            @app.get("/health")
            def health():
                return "ok"
            """,
            "app/routers/users.py": """
            router = APIRouter(prefix="/users")
            @router.get("/{user_id}")
            async def read_user(user_id: int):
                return db.execute("SELECT * FROM accounts WHERE id = ?", user_id)
            """,
            "web/app.py": """
            bp = Blueprint("shop", __name__, url_prefix="/shop")
            @bp.route("/items/<int:item_id>", methods=["GET", "DELETE"])
            def item(item_id):
                pass
            """,
            "site/urls.py": "urlpatterns = [path('blog/', include('blog.urls'))]",
            "blog/urls.py": "urlpatterns = [path('<int:pk>/', views.detail)]",
            "client/sync.py": """
            def pull(uid):
                r = requests.get(f"{BASE}/api/users/{uid}")
                httpx.delete(f"http://localhost:8000/shop/items/{uid}")
                requests.get("https://api.github.com/users/x")
            """,
            "db/schema.sql": "CREATE TABLE accounts (id int);",
        ], functions: [("app/routers/users.py", "read_user", 3), ("client/sync.py", "pull", 1)])
        let (doc, _) = Bridges.extract(root: root, graph: g)
        let routes = Set(doc.nodes.filter { $0.type == "route" }.map(\.label))
        #expect(routes.isSuperset(of: ["GET /health", "GET /api/users/:user_id", "GET /shop/items/:item_id", "DELETE /shop/items/:item_id", "* /blog/:pk"]))
        #expect(edges(doc, "requests") == ["fn:pull→mapo:route:GET /api/users/:user_id", "fn:pull→mapo:route:DELETE /shop/items/:item_id"])
        #expect(edges(doc, "reads") == ["fn:read_user→mapo:table:accounts"])
    }

    @Test func cloudflareWorkerAndServiceBinding() throws {
        let (root, g) = try project([
            "workers/auth/src/index.ts": """
            export default {
              async fetch(request, env) {
                const url = new URL(request.url)
                if (url.pathname === '/verify') return verify(request, env)
                switch (url.pathname) {
                  case '/logout': return new Response('bye')
                }
              },
            }
            """,
            "workers/api/src/index.ts": """
            export async function guard(req, env) {
              const r = await env.AUTH.fetch('https://auth/verify', { method: 'POST' })
              const x = await fetch('https://api.stripe.com/verify')
            }
            """,
        ], functions: [("workers/api/src/index.ts", "guard", 1)])
        let (doc, _) = Bridges.extract(root: root, graph: g)
        #expect(Set(doc.nodes.filter { $0.type == "route" }.map(\.label)) == ["* /verify", "* /logout"])
        // Service binding matched; a public API with the same path isn't.
        #expect(edges(doc, "requests") == ["fn:guard→mapo:route:* /verify"])
    }

    @Test func spansAndInlineHandlers() throws {
        let src = """
        import { Hono } from 'hono'
        const r = new Hono()
        export function Card({ a, b }: { a: number; b: string }) {
          const q = 'SELECT * FROM items'
          return q
        }
        export const one = (x) => db.prepare('SELECT * FROM items')
        export const two = () => 1
        r.get('/items', async (c) => {
          const rows = await c.env.DB.prepare('INSERT INTO items VALUES (1)').run()
          return c.json(rows)
        })
        export function outer() {
          function inner() {
            return 'UPDATE items SET a = 1'
          }
          return 'SELECT 1 FROM items'
        }
        """
        let (root, g) = try project([
            "api/index.ts": src,
            "db.sql": "CREATE TABLE items (a int);",
        ], functions: [("api/index.ts", "Card", 3), ("api/index.ts", "one", 7), ("api/index.ts", "two", 8), ("api/index.ts", "outer", 13), ("api/index.ts", "inner", 14)])
        let (doc, _) = Bridges.extract(root: root, graph: g)
        #expect(edges(doc, "reads") == ["fn:Card→mapo:table:items", "fn:one→mapo:table:items", "fn:outer→mapo:table:items"])
        #expect(edges(doc, "writes") == ["mapo:route:GET /items→mapo:table:items", "fn:inner→mapo:table:items"])
        let lines = src.components(separatedBy: "\n")
        #expect(Bridges.Spans.braceEnd(lines, start: 3) == 6)
        #expect(Bridges.Spans.braceEnd(lines, start: 7) == 7)
        #expect(Bridges.Spans.braceEnd(lines, start: 13) == 18)
    }
}
