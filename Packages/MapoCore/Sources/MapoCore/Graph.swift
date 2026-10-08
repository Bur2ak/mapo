import Foundation

/// A code knowledge graph as produced by graphify (networkx node-link JSON),
/// indexed for fast traversal.
///
/// Node and edge ids are interned to `Int` positions so traversals never hash
/// strings; the original string ids stay available on the values.
public struct Graph: Sendable {
    public let nodes: [Node]
    public let edges: [Edge]
    /// Commit the graph was built at, when graphify recorded one.
    public let builtAtCommit: String?

    /// Outgoing edge positions per node position.
    public let outgoing: [[Int]]
    /// Incoming edge positions per node position.
    public let incoming: [[Int]]

    private let positionByID: [String: Int]

    public init(nodes: [Node], edges: [Edge], builtAtCommit: String? = nil) {
        var positionByID: [String: Int] = [:]
        positionByID.reserveCapacity(nodes.count)
        var uniqueNodes: [Node] = []
        uniqueNodes.reserveCapacity(nodes.count)
        for node in nodes where positionByID[node.id] == nil {
            positionByID[node.id] = uniqueNodes.count
            uniqueNodes.append(node)
        }

        var outgoing = Array(repeating: [Int](), count: uniqueNodes.count)
        var incoming = Array(repeating: [Int](), count: uniqueNodes.count)
        var keptEdges: [Edge] = []
        keptEdges.reserveCapacity(edges.count)
        for var edge in edges {
            // Edges pointing at nodes graphify did not emit (rare, external
            // symbols) are dropped instead of crashing traversals.
            guard let s = positionByID[edge.source], let t = positionByID[edge.target] else { continue }
            edge.sourcePosition = s
            edge.targetPosition = t
            outgoing[s].append(keptEdges.count)
            incoming[t].append(keptEdges.count)
            keptEdges.append(edge)
        }

        self.nodes = uniqueNodes
        self.edges = keptEdges
        self.builtAtCommit = builtAtCommit
        self.outgoing = outgoing
        self.incoming = incoming
        self.positionByID = positionByID
    }

    public func position(of id: String) -> Int? { positionByID[id] }

    public func node(_ id: String) -> Node? {
        positionByID[id].map { nodes[$0] }
    }
}

public struct Node: Sendable, Hashable, Identifiable {
    public let id: String
    /// Display label as graphify wrote it, e.g. `kulupSohbetiAc()` or `routes/kulup.ts`.
    public let label: String
    public let kind: Kind
    public let sourceFile: String?
    /// 1-based line, parsed from graphify's `L42` form.
    public let line: Int?
    public let community: Int?

    public init(id: String, label: String, kind: Kind, sourceFile: String?, line: Int?, community: Int?) {
        self.id = id
        self.label = label
        self.kind = kind
        self.sourceFile = sourceFile
        self.line = line
        self.community = community
    }

    /// Label without call parentheses or leading dot, for search and display.
    public var name: String {
        var s = Substring(label)
        if s.hasSuffix("()") { s = s.dropLast(2) }
        if s.hasPrefix(".") { s = s.dropFirst() }
        return String(s)
    }

    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case file
        case function
        case method
        case type
        case symbol
        case external
        case document
        /// `GET /api/kulup/:id`, found by `Bridges` in a server file.
        case route
        /// A database table, from `CREATE TABLE` in a `.sql` file.
        case table
    }
}

public struct Edge: Sendable, Hashable {
    public let source: String
    public let target: String
    public let relation: Relation
    public let confidence: Confidence
    public let sourceFile: String?
    public let line: Int?

    /// Filled in by `Graph.init`.
    public internal(set) var sourcePosition: Int = -1
    public internal(set) var targetPosition: Int = -1

    public init(source: String, target: String, relation: Relation, confidence: Confidence, sourceFile: String?, line: Int?) {
        self.source = source
        self.target = target
        self.relation = relation
        self.confidence = confidence
        self.sourceFile = sourceFile
        self.line = line
    }
}

/// Edge relation. Open set: graphify adds relations over time, unknown ones
/// are kept verbatim instead of failing the load.
public struct Relation: RawRepresentable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let calls: Relation = "calls"
    public static let indirectCall: Relation = "indirect_call"
    public static let imports: Relation = "imports"
    public static let importsFrom: Relation = "imports_from"
    public static let contains: Relation = "contains"
    public static let method: Relation = "method"
    public static let references: Relation = "references"
    public static let inherits: Relation = "inherits"
    public static let reExports: Relation = "re_exports"
    public static let dynamicImport: Relation = "dynamic_import"
    /// Client code → HTTP route (Bridges).
    public static let requests: Relation = "requests"
    /// Code → table (Bridges).
    public static let reads: Relation = "reads"
    public static let writes: Relation = "writes"

    public var isCall: Bool { self == .calls || self == .indirectCall }
    public var isImport: Bool {
        self == .imports || self == .importsFrom || self == .reExports || self == .dynamicImport
    }
}

public enum Confidence: String, Sendable, Hashable {
    /// Explicit in source.
    case extracted = "EXTRACTED"
    /// Resolved by the engine (e.g. dynamic dispatch).
    case inferred = "INFERRED"
    /// Ambiguous resolution.
    case ambiguous = "AMBIGUOUS"
}
