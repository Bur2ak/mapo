import Foundation

/// Mermaid flowcharts of what the user is looking at, to paste into a PR,
/// a doc or a chat with an agent.
public enum MermaidExport {
    /// A node and its direct links: callers/callees, HTTP and SQL bridges,
    /// imports; for a file, the files it uses and that use it.
    public static func neighborhood(of position: Int, in graph: Graph, limit: Int = 12) -> String {
        var b = Builder(graph: graph)
        let center = b.id(position)
        b.highlight(center)
        let node = graph.nodes[position]
        if node.kind == .file {
            let deps = graph.fileDependencies(of: position)
            for d in deps.uses.prefix(limit) { b.edge(center, b.id(d.file), "uses ×\(d.weight)") }
            for d in deps.usedBy.prefix(limit) { b.edge(b.id(d.file), center, "uses ×\(d.weight)") }
        } else {
            var seen = Set<String>()
            func add(_ edges: [Int], incoming: Bool) {
                var count = 0
                for e in edges where count < limit {
                    let edge = graph.edges[e]
                    guard !edge.relation.isContainment else { continue }
                    let other = incoming ? edge.sourcePosition : edge.targetPosition
                    guard graph.nodes[other].kind != .external, other != position else { continue }
                    let key = "\(incoming)\(other)\(edge.relation.rawValue)"
                    guard seen.insert(key).inserted else { continue }
                    let o = b.id(other)
                    if incoming { b.edge(o, center, verb(edge.relation)) } else { b.edge(center, o, verb(edge.relation)) }
                    count += 1
                }
            }
            add(graph.incoming[position], incoming: true)
            add(graph.outgoing[position], incoming: false)
        }
        return b.text
    }

    /// A path found by the path finder, step by step.
    public static func path(_ result: Graph.PathResult, in graph: Graph) -> String {
        var b = Builder(graph: graph)
        let ids = result.nodes.map { b.id($0) }
        if let first = ids.first { b.highlight(first) }
        if let last = ids.last { b.highlight(last) }
        for (i, e) in result.edges.enumerated() {
            let edge = graph.edges[e]
            let forward = edge.sourcePosition == result.nodes[i]
            if forward { b.edge(ids[i], ids[i + 1], verb(edge.relation)) } else { b.edge(ids[i + 1], ids[i], verb(edge.relation)) }
        }
        return b.text
    }

    static func verb(_ r: Relation) -> String {
        if r.isCall { return "calls" }
        if r.isImport { return "imports" }
        switch r {
        case .requests: return "HTTP"
        case .reads: return "reads"
        case .writes: return "writes"
        case .inherits: return "inherits"
        default: return r.rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }

    struct Builder {
        let graph: Graph
        private var ids: [Int: String] = [:]
        private var lines: [String] = []
        private var edges: [String] = []
        private var styles: [String] = []

        init(graph: Graph) { self.graph = graph }

        mutating func id(_ p: Int) -> String {
            if let id = ids[p] { return id }
            let id = "n\(ids.count)"
            ids[p] = id
            let n = graph.nodes[p]
            let name = n.kind == .file ? n.label : n.name
            let place = n.kind == .file ? (n.sourceFile.map { ($0 as NSString).deletingLastPathComponent } ?? "") : (n.sourceFile ?? "")
            let label = place.isEmpty ? escape(name) : "\(escape(name))<br/><small>\(escape(place))</small>"
            let shape: (String, String) = switch n.kind {
            case .file: ("[", "]")
            case .route: ("[/", "/]")
            case .table: ("[(", ")]")
            default: ("(", ")")
            }
            lines.append("  \(id)\(shape.0)\"\(label)\"\(shape.1)")
            return id
        }

        mutating func edge(_ a: String, _ b: String, _ label: String) {
            edges.append("  \(a) -->|\(escape(label))| \(b)")
        }

        mutating func highlight(_ id: String) {
            styles.append("  style \(id) stroke:#F0AE47,stroke-width:3px")
        }

        var text: String { (["flowchart LR"] + lines + edges + styles).joined(separator: "\n") + "\n" }

        /// Mermaid labels are quoted; quotes and angle brackets become entities.
        private func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\"", with: "#quot;")
                .replacingOccurrences(of: "<", with: "#lt;")
                .replacingOccurrences(of: ">", with: "#gt;")
                .replacingOccurrences(of: "|", with: "#124;")
        }
    }
}
