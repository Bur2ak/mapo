import Foundation

/// Read-only questions people (and agents) ask of a code graph.
public extension Graph {
    struct Link: Sendable, Hashable {
        public let node: Int
        public let edge: Int
    }

    /// Who calls this node.
    func callers(of position: Int) -> [Link] {
        incoming[position].compactMap { e in
            edges[e].relation.isCall ? Link(node: edges[e].sourcePosition, edge: e) : nil
        }
    }

    /// What this node calls.
    func callees(of position: Int) -> [Link] {
        outgoing[position].compactMap { e in
            edges[e].relation.isCall ? Link(node: edges[e].targetPosition, edge: e) : nil
        }
    }

    /// Files / modules importing this node.
    func importers(of position: Int) -> [Link] {
        incoming[position].compactMap { e in
            edges[e].relation.isImport ? Link(node: edges[e].sourcePosition, edge: e) : nil
        }
    }

    /// What this node imports.
    func imports(of position: Int) -> [Link] {
        outgoing[position].compactMap { e in
            edges[e].relation.isImport ? Link(node: edges[e].targetPosition, edge: e) : nil
        }
    }

    /// Symbols declared inside this node (file → functions, class → methods).
    func children(of position: Int) -> [Int] {
        outgoing[position].compactMap { e in
            let r = edges[e].relation
            return (r == .contains || r == .method) ? edges[e].targetPosition : nil
        }
    }

    /// The node that declares this one (function → file).
    func parent(of position: Int) -> Int? {
        incoming[position].first { e in
            let r = edges[e].relation
            return r == .contains || r == .method
        }.map { edges[$0].sourcePosition }
    }

    /// Every directly connected node, both directions, deduplicated.
    func neighbors(of position: Int) -> Set<Int> {
        var out = Set<Int>()
        for e in outgoing[position] { out.insert(edges[e].targetPosition) }
        for e in incoming[position] { out.insert(edges[e].sourcePosition) }
        out.remove(position)
        return out
    }

    /// Shortest path between two nodes. Follows edge direction first (the
    /// "how does A reach B" answer); if none exists, falls back to an
    /// undirected path so the user still sees how the two relate.
    ///
    /// Containment edges are traversed only upward/downward between a file
    /// and its own symbols, never as shortcuts between unrelated files.
    func shortestPath(from start: Int, to goal: Int, directed: Bool? = nil) -> PathResult? {
        if start == goal { return PathResult(nodes: [start], edges: [], directed: true) }
        if directed != false, let p = bfs(from: start, to: goal, undirected: false) { return p }
        if directed != true, let p = bfs(from: start, to: goal, undirected: true) { return p }
        return nil
    }

    struct PathResult: Sendable, Equatable {
        public let nodes: [Int]
        public let edges: [Int]
        /// False when the path had to ignore edge direction.
        public let directed: Bool
    }

    private func bfs(from start: Int, to goal: Int, undirected: Bool) -> PathResult? {
        var cameFrom = [Int: (node: Int, edge: Int)]()
        var queue = [start]
        var head = 0
        cameFrom[start] = (-1, -1)
        while head < queue.count {
            let cur = queue[head]; head += 1
            var steps: [(Int, Int)] = outgoing[cur].map { (edges[$0].targetPosition, $0) }
            if undirected { steps += incoming[cur].map { (edges[$0].sourcePosition, $0) } }
            for (next, e) in steps where cameFrom[next] == nil {
                cameFrom[next] = (cur, e)
                if next == goal {
                    var nodes = [goal], path: [Int] = []
                    var at = goal
                    while let step = cameFrom[at], step.node >= 0 {
                        path.append(step.edge)
                        nodes.append(step.node)
                        at = step.node
                    }
                    return PathResult(nodes: nodes.reversed(), edges: path.reversed(), directed: !undirected)
                }
                queue.append(next)
            }
        }
        return nil
    }

    /// Blast radius: what may break if `position` changes.
    ///
    /// Walks *incoming* dependency edges (calls, imports, references,
    /// inheritance) breadth-first. A file's impact includes its symbols'
    /// dependents, since editing a file edits them. Returns rings by distance
    /// (ring 0 is the node itself and, for files, its symbols).
    func impact(of position: Int, maxDepth: Int = 3) -> [[Int]] {
        var seen = Set<Int>()
        var ring = [position] + children(of: position)
        ring.forEach { seen.insert($0) }
        var rings = [ring]
        for _ in 0..<maxDepth {
            var next: [Int] = []
            for n in ring {
                for e in incoming[n] {
                    let edge = edges[e]
                    guard edge.relation != .contains, edge.relation != .method else { continue }
                    let dependent = edge.sourcePosition
                    if nodes[dependent].kind == .external { continue }
                    if seen.insert(dependent).inserted { next.append(dependent) }
                }
            }
            if next.isEmpty { break }
            rings.append(next)
            ring = next
        }
        return rings
    }

    /// Nodes whose source file is in `paths` (repo-relative), e.g. from a git diff.
    func nodes(inFiles paths: Set<String>) -> [Int] {
        nodes.indices.filter { i in
            guard let f = nodes[i].sourceFile else { return false }
            return paths.contains(f)
        }
    }
}
