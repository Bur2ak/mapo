import Foundation

/// Fuzzy symbol / file search, tuned for code identifiers.
///
/// Scoring follows the fzf family: every query character must appear in
/// order; consecutive runs, word boundaries (camelCase humps, `/ _ . -`) and
/// prefix matches score higher; gaps cost. Matching is case-insensitive and
/// folds Turkish letters (ı→i, ş→s, ğ→g, ç→c, ö→o, ü→u) so `kulupsohbet`
/// finds `kulüpSohbeti`.
public struct SearchIndex: Sendable {
    public struct Hit: Sendable, Hashable {
        public let position: Int
        public let score: Int
        /// Matched character offsets in `Node.name` (for highlighting), empty
        /// when the match came from the file path.
        public let ranges: [Int]
    }

    private struct Entry: Sendable {
        let position: Int
        let name: [UInt8]
        let boundaries: [Bool]
        let path: [UInt8]
        let pathBoundaries: [Bool]
        let kindBonus: Int
    }

    private let entries: [Entry]

    public init(graph: Graph) {
        entries = graph.nodes.enumerated().compactMap { position, node in
            guard node.kind != .external else { return nil }
            let name = Array(node.name)
            let path = Array(node.sourceFile ?? "")
            // Test helpers and generated/config files rank below real code
            // with the same name (searching "kulup" should land on the route,
            // not on a test's local `kulup` helper).
            let file = node.sourceFile ?? ""
            let demote = (MapPayload.isTestPath(file) || NoiseFilter.isNoise(path: file)) ? 35 : 0
            return Entry(
                position: position,
                name: SearchIndex.fold(name),
                boundaries: SearchIndex.boundaries(name),
                path: SearchIndex.fold(path),
                pathBoundaries: SearchIndex.boundaries(path),
                kindBonus: SearchIndex.kindBonus(node.kind) - demote
            )
        }
    }

    public func search(_ query: String, limit: Int = 50) -> [Hit] {
        let q = SearchIndex.fold(Array(query.filter { !$0.isWhitespace }))
        guard !q.isEmpty else { return [] }

        var hits: [Hit] = []
        hits.reserveCapacity(64)
        for e in entries {
            if let (score, ranges) = SearchIndex.match(q, in: e.name, boundaries: e.boundaries) {
                let lengthPenalty = max(0, e.name.count - q.count) / 3
                hits.append(Hit(position: e.position, score: score + e.kindBonus - lengthPenalty, ranges: ranges))
            } else if q.count >= 3, let (score, _) = SearchIndex.match(q, in: e.path, boundaries: e.pathBoundaries) {
                // Path-only matches rank below any name match of similar quality.
                hits.append(Hit(position: e.position, score: score / 2 + e.kindBonus - 40, ranges: []))
            }
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.position < $1.position }
        return Array(hits.prefix(limit))
    }

    // MARK: - Matching

    /// Best-alignment subsequence match (dynamic programming, O(|q|·|s|)).
    /// Returns the score and the matched offsets, or nil when `q` is not a
    /// subsequence of `s`.
    static func match(_ q: [UInt8], in s: [UInt8], boundaries: [Bool]) -> (Int, [Int])? {
        let m = q.count, n = s.count
        guard m > 0, m <= n else { return nil }

        // Cheap subsequence check before allocating.
        var i = 0
        for c in q {
            while i < n && s[i] != c { i += 1 }
            guard i < n else { return nil }
            i += 1
        }

        let none = Int.min / 4
        // score[k][j]: best score with q[k] matched at s[j].
        var score = Array(repeating: Array(repeating: none, count: n), count: m)
        var back = Array(repeating: Array(repeating: -1, count: n), count: m)

        func charScore(_ j: Int) -> Int { 16 + (boundaries[j] ? 24 : 0) }

        for j in 0..<n where s[j] == q[0] {
            score[0][j] = charScore(j) + (j == 0 ? 30 : 0) - min(j, 12)
        }
        for k in 1..<m {
            // Running best of score[k-1][j'] + gapPenalty·j' for j' < j - 1
            // (gap cost is linear: 2 per skipped char).
            var bestGap = none, bestGapAt = -1
            for j in k..<n {
                let jp = j - 2
                if jp >= 0, score[k - 1][jp] > none {
                    let v = score[k - 1][jp] + 2 * jp
                    if v > bestGap { bestGap = v; bestGapAt = jp }
                }
                guard s[j] == q[k] else { continue }
                var best = none, from = -1
                if score[k - 1][j - 1] > none {
                    best = score[k - 1][j - 1] + 20  // consecutive
                    from = j - 1
                }
                if bestGap > none {
                    // score[jp] - 2·(j - jp - 1)
                    let v = bestGap - 2 * j + 2
                    if v > best { best = v; from = bestGapAt }
                }
                if from >= 0 {
                    score[k][j] = best + charScore(j)
                    back[k][j] = from
                }
            }
        }

        var end = -1, total = none
        for j in 0..<n where score[m - 1][j] > total { total = score[m - 1][j]; end = j }
        guard end >= 0 else { return nil }

        var ranges = Array(repeating: 0, count: m)
        var j = end
        for k in stride(from: m - 1, through: 0, by: -1) {
            ranges[k] = j
            j = back[k][j]
        }
        if m == n { total += 60 }  // exact
        return (total, ranges)
    }

    // MARK: - Normalisation

    static func fold(_ chars: [Character]) -> [UInt8] {
        chars.map { ch -> UInt8 in
            switch ch {
            case "ı", "I", "İ", "i": return UInt8(ascii: "i")
            case "ş", "Ş": return UInt8(ascii: "s")
            case "ğ", "Ğ": return UInt8(ascii: "g")
            case "ç", "Ç": return UInt8(ascii: "c")
            case "ö", "Ö": return UInt8(ascii: "o")
            case "ü", "Ü": return UInt8(ascii: "u")
            default:
                guard let a = ch.asciiValue else { return UInt8(ascii: "?") }
                return (a >= 65 && a <= 90) ? a + 32 : a
            }
        }
    }

    static func boundaries(_ chars: [Character]) -> [Bool] {
        var out = Array(repeating: false, count: chars.count)
        for i in chars.indices {
            if i == 0 { out[i] = true; continue }
            let prev = chars[i - 1], cur = chars[i]
            if "/_.-:( ".contains(prev) { out[i] = true }
            else if prev.isLowercase && cur.isUppercase { out[i] = true }
            else if !prev.isNumber && cur.isNumber { out[i] = true }
        }
        return out
    }

    static func kindBonus(_ kind: Node.Kind) -> Int {
        switch kind {
        case .function, .type: 12
        case .method: 10
        case .file: 8
        case .symbol: 4
        case .document: 0
        case .external: -20
        }
    }
}
