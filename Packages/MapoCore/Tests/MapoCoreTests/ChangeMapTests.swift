import Foundation
import Testing
@testable import MapoCore

@Suite("Değişiklik haritası")
struct ChangeMapTests {
    @Test func parsesModifiedAddedDeletedAndQuoted() {
        let diff = """
        diff --git a/src/a.ts b/src/a.ts
        index 1..2 100644
        --- a/src/a.ts
        +++ b/src/a.ts
        @@ -12 +12 @@ export function bir() {
        -x
        +y
        @@ -40,0 +41,3 @@ function iki() {
        +a
        +b
        +c
        @@ -50,2 +53,0 @@
        -gitti
        -gitti
        diff --git a/yeni.ts b/yeni.ts
        new file mode 100644
        --- /dev/null
        +++ b/yeni.ts
        @@ -0,0 +1,2 @@
        +a
        +b
        diff --git a/eski.ts b/eski.ts
        deleted file mode 100644
        --- a/eski.ts
        +++ /dev/null
        @@ -1,3 +0,0 @@
        -a
        diff --git "a/d\\303\\266n\\303\\274\\305\\237 dosya.ts" "b/d\\303\\266n\\303\\274\\305\\237 dosya.ts"
        --- "a/d\\303\\266n\\303\\274\\305\\237 dosya.ts"
        +++ "b/d\\303\\266n\\303\\274\\305\\237 dosya.ts"
        @@ -1 +1 @@
        """
        let d = ChangeMap.parse(diff)
        #expect(d.hunks["src/a.ts"] == [12...12, 41...43, 53...53])
        #expect(d.added == ["yeni.ts"])
        #expect(d.hunks["yeni.ts"] == [1...2])
        #expect(d.deleted == ["eski.ts"])
        #expect(d.hunks["eski.ts"] == nil)
        #expect(d.hunks["dönüş dosya.ts"] == [1...1])
    }

    private func graph() -> Graph {
        func fn(_ name: String, _ line: Int, kind: Node.Kind = .function) -> Node {
            Node(id: "fn:\(name)", label: name + "()", kind: kind, sourceFile: "src/a.ts", line: line, community: nil)
        }
        let nodes = [
            Node(id: "f:a", label: "a.ts", kind: .file, sourceFile: "src/a.ts", line: 1, community: nil),
            fn("bir", 10), fn("iki", 30), fn("uc", 50),
            Node(id: "f:b", label: "b.ts", kind: .file, sourceFile: "src/b.ts", line: 1, community: nil),
            Node(id: "fn:cagiran", label: "cagiran()", kind: .function, sourceFile: "src/b.ts", line: 3, community: nil),
        ]
        let edges = ["bir", "iki", "uc"].map { Edge(source: "f:a", target: "fn:\($0)", relation: .contains, confidence: .extracted, sourceFile: "src/a.ts", line: nil) }
            + [Edge(source: "fn:cagiran", target: "fn:bir", relation: .calls, confidence: .extracted, sourceFile: "src/b.ts", line: 4)]
        return Graph(nodes: nodes, edges: edges)
    }

    @Test func linesBelongToTheNearestDeclarationAbove() {
        let g = graph()
        var d = ChangeMap.Diff()
        d.hunks["src/a.ts"] = [2...3, 12...12, 29...31]
        let c = ChangeMap.changes(in: g, diff: d)
        #expect(c.count == 1)
        let names = c[0].symbols.map { g.nodes[$0].name }
        #expect(names == ["bir", "iki"])
        #expect(c[0].header)
        #expect(c[0].file == g.position(of: "f:a"))
    }

    @Test func lastSymbolRunsToEndOfFileAndDeletionTouchesAll() {
        let g = graph()
        var d = ChangeMap.Diff()
        d.hunks["src/a.ts"] = [400...400]
        d.deleted = ["src/b.ts"]
        d.added = ["src/c.ts"]
        let c = ChangeMap.changes(in: g, diff: d)
        #expect(c.map(\.path) == ["src/a.ts", "src/b.ts", "src/c.ts"])
        #expect(c[0].symbols.map { g.nodes[$0].name } == ["uc"] && !c[0].header)
        #expect(c[1].deleted && c[1].symbols.map { g.nodes[$0].name } == ["cagiran"])
        #expect(c[2].added && c[2].file == nil && c[2].symbols.isEmpty)
    }

    @Test func onlySafeRefsReachGit() {
        for ok in ["main", "HEAD", "HEAD~3", "HEAD^", "origin/main", "v0.3.1", "a1b2c3d", "main@{1}", "erol/8-codex"] {
            #expect(ChangeMap.isSafeRef(ok), "\(ok)")
        }
        for bad in ["", "--output=/tmp/x", "-p", "main..HEAD", "a b", "x;rm", "$(id)", "`id`", "ğ", String(repeating: "a", count: 101)] {
            #expect(!ChangeMap.isSafeRef(bad), "\(bad)")
        }
        #expect(throws: ChangeMap.GitError.self) { try ChangeMap.diff(since: "--output=/tmp/mapo-x", at: URL(fileURLWithPath: "/tmp")) }
    }

    @Test func realRepository() throws {
        guard GitInfo.isAvailable else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-degisim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        func git(_ args: String...) throws {
            _ = try ChangeMap.git(["-C", root.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args)
        }
        let file = root.appendingPathComponent("src/a.ts")
        try (1...60).map { "satir \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try git("init", "-q")
        try git("add", ".")
        try git("commit", "-q", "-m", "ilk")
        var lines = (1...60).map { "satir \($0)" }
        lines[11] = "degisti"
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try "yeni".write(to: root.appendingPathComponent("src/yeni.ts"), atomically: true, encoding: .utf8)

        let d = try ChangeMap.diff(since: "HEAD", at: root)
        #expect(d.hunks["src/a.ts"] == [12...12])
        #expect(d.added == ["src/yeni.ts"])
        let names = ChangeMap.changes(in: graph(), diff: d).first { $0.path == "src/a.ts" }?.symbols.map { graph().nodes[$0].name }
        #expect(names == ["bir"])
        #expect(throws: ChangeMap.GitError.self) { try ChangeMap.diff(since: "olmayan-dal", at: root) }
    }
}
