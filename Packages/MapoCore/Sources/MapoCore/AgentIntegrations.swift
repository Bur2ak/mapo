import Foundation

/// Registers / unregisters Mapo's MCP server in coding agents' config files.
///
/// Rules, because these files belong to the user and to other tools:
/// - only Mapo's own entry (and the legacy `atlas` one) is ever changed;
/// - anything unreadable or declared in an unfamiliar shape is refused, never
///   guessed at or overwritten;
/// - the first original is kept as `*.mapo-backup` (0600), writes are atomic,
///   symlinked configs are written through, line endings are preserved.
public enum AgentIntegrations {
    public enum Client: String, CaseIterable, Identifiable, Sendable {
        case claudeCode, codex, cursor, claudeDesktop

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .cursor: "Cursor"
            case .claudeDesktop: "Claude Desktop"
            }
        }

        /// Config file, relative to the home directory.
        public var configPath: String {
            switch self {
            case .claudeCode: ".claude.json"
            case .codex: ".codex/config.toml"
            case .cursor: ".cursor/mcp.json"
            case .claudeDesktop: "Library/Application Support/Claude/claude_desktop_config.json"
            }
        }

        /// Whether the client looks installed (its config folder exists).
        public func isInstalled(home: URL) -> Bool {
            let dir = home.appendingPathComponent(configPath).deletingLastPathComponent()
            if self == .claudeCode { return FileManager.default.fileExists(atPath: home.appendingPathComponent(configPath).path) }
            return FileManager.default.fileExists(atPath: dir.path)
        }
    }

    public static let serverName = "mapo"

    public enum IntegrationError: Error, LocalizedError, Equatable {
        case unreadable(String)
        case unsupportedLayout(String)
        case unstableLocation

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path):
                String(localized: "Yapılandırma dosyası okunamadı: \(path). Dosyaya dokunulmadı; elle düzeltip tekrar dene.")
            case .unsupportedLayout(let path):
                String(localized: "\(path) içinde Mapo tanımadığım bir biçimde yazılmış. Dosyaya dokunmadım; o satırları elle kaldırıp tekrar dene.")
            case .unstableLocation:
                String(localized: "Mapo disk görüntüsünden ya da geçici bir konumdan çalışıyor. Önce Uygulamalar klasörüne taşı, sonra bağla.")
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case notConnected
        case connected
        /// Connected, but to another (moved or older) copy of Mapo.
        case outdated(command: String)
    }

    /// A path a config can point at for good: not a mounted DMG, not macOS's
    /// App Translocation scratch area.
    public static func isStableExecutable(_ path: String) -> Bool {
        !(path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/"))
    }

    public static func status(_ client: Client, executable: String, home: URL) -> Status {
        let url = home.appendingPathComponent(client.configPath).resolvingSymlinksInPath()
        guard let text = (try? readText(url)) ?? nil else { return .notConnected }
        let command: String?
        switch client {
        case .codex:
            command = TOMLDoc(text).commandOfTable(named: serverName)
        default:
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let servers = obj["mcpServers"] as? [String: Any],
                  let entry = servers[serverName] as? [String: Any] else { return .notConnected }
            command = entry["command"] as? String ?? ""
        }
        guard let command else { return .notConnected }
        return command == executable ? .connected : .outdated(command: command)
    }

    public static func isConnected(_ client: Client, home: URL) -> Bool {
        status(client, executable: "\u{0}", home: home) != .notConnected
    }

    /// Adds or updates Mapo's entry pointing at `executable`.
    public static func connect(_ client: Client, executable: String, home: URL) throws {
        guard isStableExecutable(executable) else { throw IntegrationError.unstableLocation }
        let url = home.appendingPathComponent(client.configPath).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try readText(url)
        let updated: String
        switch client {
        case .codex:
            updated = try codexConnect(existing ?? "", executable: executable, path: url.path)
        default:
            updated = try jsonUpdate(existing, path: url.path) { servers in
                servers[LegacyMigration.legacyServerName] = nil
                servers[serverName] = ["type": "stdio", "command": executable, "args": [String]()]
            }
        }
        try backUp(url, existing)
        try write(updated, to: url, existed: existing != nil)
    }

    public static func disconnect(_ client: Client, home: URL) throws {
        let url = home.appendingPathComponent(client.configPath).resolvingSymlinksInPath()
        guard let existing = try readText(url) else { return }
        let updated: String
        switch client {
        case .codex:
            updated = try codexRemove(existing, names: [serverName, LegacyMigration.legacyServerName], path: url.path)
        default:
            updated = try jsonUpdate(existing, path: url.path) { servers in
                servers[serverName] = nil
                servers[LegacyMigration.legacyServerName] = nil
            }
        }
        try backUp(url, existing)
        try write(updated, to: url, existed: true)
    }

    // MARK: - JSON clients

    static func jsonUpdate(_ text: String?, path: String, _ change: (inout [String: Any]) -> Void) throws -> String {
        var root: [String: Any] = [:]
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw IntegrationError.unreadable(path)
            }
            root = obj
        }
        if let existing = root["mcpServers"], !(existing is [String: Any]) {
            throw IntegrationError.unsupportedLayout(path)
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        change(&servers)
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Codex (TOML)

    /// Codex's config is TOML users edit by hand: no re-serialisation. Only
    /// Mapo's `[mcp_servers.mapo]` table (and legacy `atlas`) is replaced.
    static func codexConnect(_ text: String, executable: String, path: String = "config.toml") throws -> String {
        let doc = TOMLDoc(text)
        var lines = try doc.removingTables(named: [serverName, LegacyMigration.legacyServerName], path: path)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines += ["[mcp_servers.\(serverName)]", "command = \(tomlString(executable))", "args = []", ""]
        return lines.joined(separator: doc.newline)
    }

    static func codexDisconnect(_ text: String) -> String {
        (try? codexRemove(text, names: [serverName], path: "config.toml")) ?? text
    }

    static func codexRemove(_ text: String, name: String) -> String {
        (try? codexRemove(text, names: [name], path: "config.toml")) ?? text
    }

    static func codexRemove(_ text: String, names: [String], path: String) throws -> String {
        let doc = TOMLDoc(text)
        var out: [String] = []
        for line in try doc.removingTables(named: names, path: path) {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, let prev = out.last, prev.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            out.append(line)
        }
        return out.joined(separator: doc.newline)
    }

    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Files

    /// nil only when the file does not exist. Any other failure (permissions,
    /// not UTF-8) throws, so a config is never replaced by a blank one.
    static func readText(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            throw IntegrationError.unreadable(url.path)
        }
        return text
    }

    private static func backUp(_ url: URL, _ existing: String?) throws {
        guard let existing else { return }
        let backup = url.appendingPathExtension("mapo-backup")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try existing.write(to: backup, atomically: true, encoding: .utf8)
        // Configs often hold tokens: the backup is as private as the original.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }

    private static func write(_ text: String, to url: URL, existed: Bool) throws {
        let mode = existed ? (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) : nil
        try text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: mode ?? 0o600], ofItemAtPath: url.path)
    }
}

/// Just enough TOML structure to find and remove whole tables safely.
struct TOMLDoc {
    let lines: [String]
    /// The file's own line ending, restored on write.
    let newline: String

    init(_ text: String) {
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// `[a."b". c ] # note` → ["a", "b", "c"]; nil for non-headers and arrays of tables.
    static func header(_ line: String) -> [String]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), !t.hasPrefix("[[") else { return nil }
        var parts: [String] = []
        var cur = ""
        var quote: Character?
        var closed = false
        for ch in t.dropFirst() {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "]" { closed = true; break }
            switch ch {
            case "\"", "'": quote = ch
            case ".": parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            default: cur.append(ch)
            }
        }
        guard closed else { return nil }
        parts.append(cur.trimmingCharacters(in: .whitespaces))
        return parts
    }

    /// Per line: true when the line starts outside a multi-line string, so a
    /// header-looking line inside one is never treated as a table.
    func structural() -> [Bool] {
        var open: String?
        return lines.map { line in
            let startsOutside = open == nil
            var rest = Substring(line)
            while true {
                if let q = open {
                    guard let r = rest.range(of: q) else { break }
                    rest = rest[r.upperBound...]
                    open = nil
                } else {
                    let candidates = [rest.range(of: "\"\"\""), rest.range(of: "'''")].compactMap { $0 }
                    guard let r = candidates.min(by: { $0.lowerBound < $1.lowerBound }) else { break }
                    open = String(rest[r])
                    rest = rest[r.upperBound...]
                }
            }
            return startsOutside
        }
    }

    /// `command` of `[mcp_servers.<name>]`: nil when the table is absent,
    /// "" when present without a readable string command.
    func commandOfTable(named name: String) -> String? {
        let ok = structural()
        var inside = false
        var found = false
        var command = ""
        for (i, line) in lines.enumerated() where ok[i] {
            if let h = Self.header(line) {
                inside = h == ["mcp_servers", name]
                found = found || inside
                continue
            }
            guard inside else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("command"), let eq = t.firstIndex(of: "=") else { continue }
            let value = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", let end = value.lastIndex(of: "\""), end > value.startIndex {
                command = String(value[value.index(after: value.startIndex)..<end])
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
        }
        return found ? command : nil
    }

    /// Lines without `[mcp_servers.<name>]` tables (and their sub-tables).
    /// Throws when a name is declared another way — inline `name = {…}` under
    /// `[mcp_servers]`, or dotted keys — instead of risking a broken file.
    func removingTables(named names: [String], path: String) throws -> [String] {
        let ok = structural()
        var out: [String] = []
        var skipping = false
        var table: [String] = []
        for (i, line) in lines.enumerated() {
            if ok[i], let h = Self.header(line) {
                table = h
                skipping = h.count >= 2 && h[0] == "mcp_servers" && names.contains(h[1])
            } else if ok[i], !skipping {
                let key = Self.leadingKey(line)
                for name in names {
                    let inline = table == ["mcp_servers"] && key.first == name
                    let dotted = table.isEmpty && key.count >= 2 && key[0] == "mcp_servers" && key[1] == name
                    if inline || dotted { throw AgentIntegrations.IntegrationError.unsupportedLayout(path) }
                }
            }
            if !skipping { out.append(line) }
        }
        return out
    }

    /// Dotted key path before `=` (`"mapo".command = …` → ["mapo", "command"]).
    static func leadingKey(_ line: String) -> [String] {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#"), !t.hasPrefix("["), let eq = t.firstIndex(of: "=") else { return [] }
        return t[..<eq].split(separator: ".").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }
}
