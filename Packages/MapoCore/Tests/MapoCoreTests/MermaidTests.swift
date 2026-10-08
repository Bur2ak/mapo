import Foundation
import Testing
@testable import MapoCore

@Suite("Mermaid dışa aktarma")
struct MermaidTests {
    private func graph() throws -> Graph {
        let url = try #require(Bundle.module.url(forResource: "kucuk", withExtension: "json", subdirectory: "Fixtures"))
        return try GraphLoader.load(from: url).0
    }

    @Test func symbolNeighborhood() throws {
        let g = try graph()
        let p = try #require(g.position(of: "fn_ac"))
        let m = MermaidExport.neighborhood(of: p, in: g)
        #expect(m.hasPrefix("flowchart LR\n"))
        #expect(m.contains(#"n0("kulupSohbetiAc<br/><small>apps/mobile/lib/kulupSohbet.ts</small>")"#))
        // Caller → it, it → callee; containment and missing nodes are left out.
        #expect(m.contains("-->|calls| n0"))
        #expect(m.contains("n0 -->|calls|"))
        #expect(m.contains("KulupSayfasi") && m.contains("kulupOzelSohbetAc"))
        #expect(!m.contains("kulupSohbet.ts\"]"))  // its own file isn't a neighbour
        #expect(m.contains("style n0 stroke:#F0AE47"))
    }

    @Test func fileNeighborhoodAndPath() throws {
        let g = try graph()
        let f = try #require(g.position(of: "f_kulup"))
        let m = MermaidExport.neighborhood(of: f, in: g)
        #expect(m.contains(#"n0["kulupSohbet.ts<br/><small>apps/mobile/lib</small>"]"#))
        #expect(m.contains("n0 -->|uses ×"))
        let from = try #require(g.position(of: "c_sayfa"))
        let to = try #require(g.position(of: "fn_istek"))
        let path = try #require(g.shortestPath(from: from, to: to))
        let pm = MermaidExport.path(path, in: g)
        #expect(pm.components(separatedBy: "-->|calls|").count - 1 == 3)
        #expect(pm.components(separatedBy: "style").count - 1 == 2)
    }

    @Test func labelsAreEscaped() {
        let g = Graph(nodes: [
            Node(id: "a", label: "f<T>()", kind: .function, sourceFile: "x \"q\".ts", line: 1, community: nil),
            Node(id: "r", label: "GET /a|b", kind: .route, sourceFile: "s.ts", line: 2, community: nil),
        ], edges: [Edge(source: "a", target: "r", relation: .requests, confidence: .inferred, sourceFile: nil, line: nil)])
        let m = MermaidExport.neighborhood(of: 0, in: g)
        #expect(m.contains("f#lt;T#gt;") && m.contains("x #quot;q#quot;.ts"))
        #expect(m.contains(#"n1[/"GET /a#124;b<br/><small>s.ts</small>"/]"#))
        #expect(m.contains("n0 -->|HTTP| n1"))
    }
}
