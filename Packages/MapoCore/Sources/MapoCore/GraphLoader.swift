import Foundation

/// Reads graphify's `graph.json` (networkx node-link format).
///
/// Decoding is deliberately lenient: graphify adds fields between versions,
/// so every field except `id` / `source` / `target` is optional and unknown
/// relation names are kept as-is.
public enum GraphLoader {
    public struct Metadata: Sendable, Equatable {
        public let schemaVersion: Int?
        public let engineVersion: String?
        public let builtAtCommit: String?
    }

    public enum LoadError: Error, LocalizedError {
        case unreadable(URL, underlying: Error)
        case malformed(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url, _):
                return String(localized: "Harita dosyası okunamadı: \(url.path)")
            case .malformed:
                return String(localized: "Harita dosyası bozuk. Projeyi yeniden indeksle.")
            }
        }
    }

    public static func load(from url: URL) throws -> (Graph, Metadata) {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw LoadError.unreadable(url, underlying: error)
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> (Graph, Metadata) {
        let raw: RawGraph
        do {
            raw = try JSONDecoder().decode(RawGraph.self, from: data)
        } catch {
            throw LoadError.malformed(underlying: error)
        }

        let nodes = raw.nodes.map { r -> Node in
            Node(
                id: r.id,
                label: r.label ?? r.id,
                kind: kind(of: r),
                sourceFile: r.sourceFile.flatMap { $0.isEmpty ? nil : $0 },
                line: parseLine(r.sourceLocation),
                community: r.community
            )
        }
        let edges = (raw.links ?? raw.edges ?? []).map { r in
            Edge(
                source: r.source,
                target: r.target,
                relation: Relation(rawValue: r.relation ?? "related"),
                confidence: r.confidence.flatMap(Confidence.init(rawValue:)) ?? .extracted,
                sourceFile: r.sourceFile,
                line: parseLine(r.sourceLocation)
            )
        }
        let meta = Metadata(
            schemaVersion: raw.graph?.schemaVersion,
            engineVersion: raw.graph?.graphifyVersion,
            builtAtCommit: raw.builtAtCommit
        )
        return (Graph(nodes: nodes, edges: edges, builtAtCommit: raw.builtAtCommit), meta)
    }

    /// `L42` → 42. graphify also emits ranges like `L42-L60`; the start wins.
    static func parseLine(_ location: String?) -> Int? {
        guard var s = location?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("L") { s.removeFirst() }
        let digits = s.prefix { $0.isNumber }
        return Int(digits)
    }

    static func kind(of r: RawNode) -> Node.Kind {
        if r.type == "external" || r.external == true { return .external }
        if r.fileType == "concept" || r.fileType == "rationale" || r.fileType == "document" || r.fileType == "paper" {
            return .document
        }
        let label = r.label ?? r.id
        if label.hasSuffix("()") { return label.hasPrefix(".") ? .method : .function }
        if r.callableClass == true { return .type }
        // graphify disambiguates same-named files with their folder
        // ("kulupler/[id].tsx"), so a label that is a path suffix is a file.
        if let file = r.sourceFile, !file.isEmpty, file == label || file.hasSuffix("/" + label) {
            return .file
        }
        return .symbol
    }

    // MARK: - Wire format

    struct RawGraph: Decodable {
        let nodes: [RawNode]
        let links: [RawEdge]?
        let edges: [RawEdge]?
        let graph: RawMeta?
        let builtAtCommit: String?

        enum CodingKeys: String, CodingKey {
            case nodes, links, edges, graph
            case builtAtCommit = "built_at_commit"
        }
    }

    struct RawMeta: Decodable {
        let schemaVersion: Int?
        let graphifyVersion: String?
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case graphifyVersion = "graphify_version"
        }
    }

    struct RawNode: Decodable {
        let id: String
        let label: String?
        let type: String?
        let external: Bool?
        let fileType: String?
        let sourceFile: String?
        let sourceLocation: String?
        let community: Int?
        let callableClass: Bool?

        enum CodingKeys: String, CodingKey {
            case id, label, type, external, community
            case fileType = "file_type"
            case sourceFile = "source_file"
            case sourceLocation = "source_location"
            case callableClass = "_callable_class"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeLossyString(.id) ?? ""
            label = try c.decodeLossyString(.label)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            external = try? c.decodeIfPresent(Bool.self, forKey: .external)
            fileType = try? c.decodeIfPresent(String.self, forKey: .fileType)
            sourceFile = try? c.decodeIfPresent(String.self, forKey: .sourceFile)
            sourceLocation = try c.decodeLossyString(.sourceLocation)
            community = try? c.decodeIfPresent(Int.self, forKey: .community)
            callableClass = try? c.decodeIfPresent(Bool.self, forKey: .callableClass)
        }
    }

    struct RawEdge: Decodable {
        let source: String
        let target: String
        let relation: String?
        let confidence: String?
        let sourceFile: String?
        let sourceLocation: String?

        enum CodingKeys: String, CodingKey {
            case source, target, relation, confidence
            case sourceFile = "source_file"
            case sourceLocation = "source_location"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decodeLossyString(.source) ?? ""
            target = try c.decodeLossyString(.target) ?? ""
            relation = try? c.decodeIfPresent(String.self, forKey: .relation)
            confidence = try? c.decodeIfPresent(String.self, forKey: .confidence)
            sourceFile = try? c.decodeIfPresent(String.self, forKey: .sourceFile)
            sourceLocation = try c.decodeLossyString(.sourceLocation)
        }
    }
}

private extension KeyedDecodingContainer {
    /// networkx happily writes integer ids; accept numbers as strings.
    func decodeLossyString(_ key: Key) throws -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        return nil
    }
}
