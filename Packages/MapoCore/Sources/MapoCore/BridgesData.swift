import Foundation

/// Databases: where tables are defined and which code reads or writes them.
extension Bridges {
    struct TableDef: Equatable {
        enum Source: Equatable { case sql, prisma, drizzle }
        let name: String
        let file: String
        let line: Int
        let source: Source
        /// Prisma client accessor (`user` for `model User`) or Drizzle variable (`users`).
        var handle: String? = nil
    }

    struct TableUse: Equatable {
        let table: String
        let file: String
        let line: Int
        let writes: Bool
    }

    // MARK: Definitions

    static let prismaModel = try! NSRegularExpression(pattern: #"(?m)^\s*model\s+([A-Za-z_]\w*)\s*\{"#)
    static let prismaMap = try! NSRegularExpression(pattern: #"@@map\(\s*(?:name\s*:\s*)?"([^"]+)"\s*\)"#)
    static let drizzleTable = try! NSRegularExpression(
        pattern: #"(?:export\s+)?const\s+([A-Za-z_$][\w$]*)\s*=\s*(?:pgTable|sqliteTable|mysqlTable|pgTableCreator\([^)]*\))\s*\(\s*['"`]([A-Za-z_]\w*)['"`]"#)

    /// Drizzle first (the code's own schema), then Prisma, then SQL migrations;
    /// a table keeps its first definition.
    static func findTables(root: URL, texts: [String: String], schemaFiles: [String]) -> [TableDef] {
        var defs: [TableDef] = []
        var seen = Set<String>()
        func add(_ d: TableDef) {
            guard seen.insert(d.name.lowercased()).inserted else { return }
            defs.append(d)
        }
        for (f, t) in texts.sorted(by: { $0.key < $1.key }) where !f.hasSuffix(".py") {
            let lines = LineIndex(t)
            for m in drizzleTable.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                guard let v = Range(m.range(at: 1), in: t), let n = Range(m.range(at: 2), in: t) else { continue }
                add(TableDef(name: String(t[n]), file: f, line: lines.line(at: m.range.location), source: .drizzle, handle: String(t[v])))
            }
        }
        for f in schemaFiles where f.hasSuffix(".prisma") {
            guard let t = read(root.appendingPathComponent(f)) else { continue }
            let lines = LineIndex(t)
            let ns = t as NSString
            for m in prismaModel.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let model = ns.substring(with: m.range(at: 1))
                let bodyStart = m.range.location + m.range.length
                let close = ns.range(of: "}", range: NSRange(location: bodyStart, length: ns.length - bodyStart))
                let body = close.location == NSNotFound ? "" : ns.substring(with: NSRange(location: bodyStart, length: close.location - bodyStart))
                let mapped = prismaMap.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)).flatMap { Range($0.range(at: 1), in: body) }.map { String(body[$0]) }
                let accessor = model.prefix(1).lowercased() + model.dropFirst()
                add(TableDef(name: mapped ?? model, file: f, line: lines.line(at: m.range.location), source: .prisma, handle: accessor))
            }
        }
        for f in schemaFiles where f.hasSuffix(".sql") {
            guard let t = read(root.appendingPathComponent(f)) else { continue }
            let lines = LineIndex(t)
            for m in createTable.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                guard let r = Range(m.range(at: 1), in: t) else { continue }
                add(TableDef(name: t[r].lowercased(), file: f, line: lines.line(at: m.range.location), source: .sql))
            }
        }
        return defs
    }

    // MARK: Uses

    static let supabaseFrom = try! NSRegularExpression(
        pattern: #"\.from\(\s*['"`]([A-Za-z_]\w*)['"`]\s*\)\s*\.\s*([A-Za-z_]\w*)"#)
    static let prismaCall = try! NSRegularExpression(
        pattern: #"\b[A-Za-z_$][\w$]*\s*\.\s*([A-Za-z_$][\w$]*)\s*\.\s*(findMany|findUnique|findUniqueOrThrow|findFirst|findFirstOrThrow|count|aggregate|groupBy|create|createMany|createManyAndReturn|update|updateMany|updateManyAndReturn|upsert|delete|deleteMany)\s*\("#)
    static let drizzleUse = try! NSRegularExpression(
        pattern: #"(?<!Array)(?<!Buffer)(?<!Object)(?<!Promise)\.\s*(from|join|leftJoin|rightJoin|innerJoin|fullJoin|insert|update|delete)\s*\(\s*([A-Za-z_$][\w$]*)\s*[,)]"#)
    static let drizzleQuery = try! NSRegularExpression(pattern: #"\.query\s*\.\s*([A-Za-z_$][\w$]*)\s*\.\s*(findMany|findFirst)\b"#)

    static func findTableUses(texts: [String: String], tables: [TableDef]) -> [TableUse] {
        var names: [String: String] = [:], prismaNames: [String: String] = [:], drizzleNames: [String: String] = [:]
        for t in tables {
            names[t.name.lowercased()] = t.name
            if t.source == .prisma, let h = t.handle { prismaNames[h] = t.name }
            if t.source == .drizzle, let h = t.handle { drizzleNames[h] = t.name }
        }
        let byName = names, prisma = prismaNames, drizzle = drizzleNames
        return perFile(texts) { f, t in
            var uses: [TableUse] = []
            let lines = LineIndex(t)
            let ns = t as NSString
            let all = NSRange(location: 0, length: ns.length)
            func add(_ name: String?, _ loc: Int, _ writes: Bool) {
                guard let name else { return }
                uses.append(TableUse(table: name, file: f, line: lines.line(at: loc), writes: writes))
            }
            // Raw SQL in strings (also D1 / better-sqlite3 / psql).
            for m in sqlUse.matches(in: t, range: all) {
                let kw = ns.substring(with: m.range(at: 1))
                add(byName[ns.substring(with: m.range(at: 2)).lowercased()], m.range.location, !["FROM", "JOIN"].contains(kw))
            }
            guard !f.hasSuffix(".py") else { return uses }
            // Supabase: .from('table').select() reads; insert/update/upsert/delete write.
            for m in supabaseFrom.matches(in: t, range: all) {
                let op = ns.substring(with: m.range(at: 2))
                add(byName[ns.substring(with: m.range(at: 1)).lowercased()], m.range.location, ["insert", "update", "upsert", "delete"].contains(op))
            }
            if !prisma.isEmpty {
                for m in prismaCall.matches(in: t, range: all) {
                    let op = ns.substring(with: m.range(at: 2))
                    add(prisma[ns.substring(with: m.range(at: 1))], m.range.location, !op.hasPrefix("find") && !["count", "aggregate", "groupBy"].contains(op))
                }
            }
            if !drizzle.isEmpty {
                for m in drizzleUse.matches(in: t, range: all) {
                    let op = ns.substring(with: m.range(at: 1))
                    add(drizzle[ns.substring(with: m.range(at: 2))], m.range.location, ["insert", "update", "delete"].contains(op))
                }
                for m in drizzleQuery.matches(in: t, range: all) {
                    add(drizzle[ns.substring(with: m.range(at: 1))], m.range.location, false)
                }
            }
            return uses
        }
    }
}
