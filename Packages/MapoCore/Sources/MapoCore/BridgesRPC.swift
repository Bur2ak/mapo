import Foundation

/// tRPC: procedures defined in routers (`router({ user: userRouter })`,
/// `byId: publicProcedure.input(…).query(…)`) and client calls
/// (`trpc.user.byId.useQuery(…)`, `api.post.create.mutate(…)`).
extension Bridges {
    static let trpcRouter = try! NSRegularExpression(
        pattern: #"(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:createTRPCRouter|router|t\.router|createRouter|trpc\.router)\s*\(\s*\{"#)
    static let trpcClient = try! NSRegularExpression(
        pattern: #"\b(?:trpc|api|client|utils|trpcClient|apiClient)\s*\.\s*((?:[A-Za-z_$][\w$]*\s*\.\s*)+?)(useQuery|useSuspenseQuery|useInfiniteQuery|useSuspenseInfiniteQuery|useMutation|useSubscription|query|mutate|mutation|fetch|prefetch|invalidate|getData|setData|ensureData|queryOptions|mutationOptions)\b"#)

    struct Procedure: Equatable {
        let path: String
        let kind: String  // QUERY / MUTATION / SUBSCRIPTION
        let file: String
        let line: Int
    }

    static func findProcedures(texts: [String: String]) -> [Procedure] {
        // router variable → (file, entries)
        struct Entry { let key: String; let child: String?; let kind: String?; let line: Int }
        var routers: [String: (file: String, entries: [Entry])] = [:]
        for (f, t) in texts where !f.hasSuffix(".py") {
            let ns = t as NSString
            let lines = LineIndex(t)
            for m in trpcRouter.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                let open = m.range.location + m.range.length - 1
                var entries: [Entry] = []
                for (key, value, at) in topLevelEntries(ns, openBrace: open) {
                    let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if v.range(of: #"^[A-Za-z_$][\w$]*$"#, options: .regularExpression) != nil {
                        entries.append(Entry(key: key, child: v, kind: nil, line: lines.line(at: at)))
                    } else if let kind = [".subscription(": "SUBSCRIPTION", ".mutation(": "MUTATION", ".query(": "QUERY"]
                        .first(where: { v.contains($0.key) })?.value {
                        entries.append(Entry(key: key, child: nil, kind: kind, line: lines.line(at: at)))
                    }
                }
                if !entries.isEmpty { routers[name] = (f, entries) }
            }
        }
        let children = Set(routers.values.flatMap { $0.entries.compactMap(\.child) })
        var out: [Procedure] = []
        func walk(_ router: String, _ prefix: String, _ depth: Int) {
            guard depth < 8, let r = routers[router] else { return }
            for e in r.entries {
                let path = prefix.isEmpty ? e.key : prefix + "." + e.key
                if let c = e.child { walk(c, path, depth + 1) }
                if let k = e.kind { out.append(Procedure(path: path, kind: k, file: r.file, line: e.line)) }
            }
        }
        for root in routers.keys.sorted() where !children.contains(root) { walk(root, "", 0) }
        return out
    }

    /// `{ a: x, b: y.query(() => { … }), }` → [("a", "x"), ("b", "y.query(…)")],
    /// splitting only at depth-1 commas (strings and nested brackets skipped).
    static func topLevelEntries(_ ns: NSString, openBrace: Int) -> [(String, String, Int)] {
        var entries: [(String, String, Int)] = []
        var depth = 0, i = openBrace, start = openBrace + 1
        var quote: unichar = 0
        let end = min(ns.length, openBrace + 200_000)
        func flush(_ upTo: Int) {
            guard upTo > start else { return }
            let piece = ns.substring(with: NSRange(location: start, length: upTo - start))
            guard let colon = piece.firstIndex(of: ":") else { return }
            let key = piece[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\"`"))
            guard key.range(of: #"^[A-Za-z_$][\w$]*$"#, options: .regularExpression) != nil else { return }
            let keyOffset = start + (piece.distance(from: piece.startIndex, to: piece.firstIndex { !$0.isWhitespace } ?? piece.startIndex))
            entries.append((key, String(piece[piece.index(after: colon)...]), keyOffset))
        }
        while i < end {
            let c = ns.character(at: i)
            if quote != 0 {
                if c == quote && ns.character(at: i - 1) != 92 { quote = 0 }
            } else {
                switch c {
                case 34, 39, 96: quote = c                       // " ' `
                case 123, 40, 91: depth += 1                     // { ( [
                case 125, 41, 93:                                // } ) ]
                    depth -= 1
                    if depth == 0 { flush(i); return entries }
                case 44 where depth == 1:                        // ,
                    flush(i)
                    start = i + 1
                default: break
                }
            }
            i += 1
        }
        return entries
    }

    struct RPCCall: Equatable { let path: String; let file: String; let line: Int }

    static func findRPCCalls(texts: [String: String]) -> [RPCCall] {
        var calls: [RPCCall] = []
        for (f, t) in texts where !f.hasSuffix(".py") {
            let ns = t as NSString
            let lines = LineIndex(t)
            for m in trpcClient.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let path = ns.substring(with: m.range(at: 1)).filter { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                calls.append(RPCCall(path: path, file: f, line: lines.line(at: m.range.location)))
            }
        }
        return calls
    }
}
