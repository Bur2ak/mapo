import Foundation

/// Registers / unregisters Atlas's MCP server in coding agents' config files.
///
/// Every write: back up the original once (`*.atlas-backup`), change only
/// Atlas's own entry, keep every other setting byte-for-byte where the format
/// allows, write atomically.
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

    public static let serverName = "atlas"

    public enum IntegrationError: Error, LocalizedError, Equatable {
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let path): String(localized: "Yapılandırma dosyası okunamadı: \(path). Elle düzeltip tekrar dene.")
            }
        }
    }

    public static func isConnected(_ client: Client, home: URL) -> Bool {
        let url = home.appendingPathComponent(client.configPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        switch client {
        case .codex:
            return text.range(of: #"(?m)^\[mcp_servers\.atlas\]"#, options: .regularExpression) != nil
        default:
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let servers = obj["mcpServers"] as? [String: Any] else { return false }
            return servers[serverName] != nil
        }
    }

    /// Adds or updates Atlas's entry pointing at `executable`.
    public static func connect(_ client: Client, executable: String, home: URL) throws {
        let url = home.appendingPathComponent(client.configPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        backUp(url, existing)
        let updated: String
        switch client {
        case .codex:
            updated = codexConnect(existing ?? "", executable: executable)
        default:
            updated = try jsonUpdate(existing, path: url.path) { servers in
                servers[serverName] = ["type": "stdio", "command": executable, "args": [String]()]
            }
        }
        try write(updated, to: url, keepingModeOf: existing == nil ? nil : url)
    }

    public static func disconnect(_ client: Client, home: URL) throws {
        let url = home.appendingPathComponent(client.configPath)
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
        backUp(url, existing)
        let updated: String
        switch client {
        case .codex:
            updated = codexDisconnect(existing)
        default:
            updated = try jsonUpdate(existing, path: url.path) { servers in servers[serverName] = nil }
        }
        try write(updated, to: url, keepingModeOf: url)
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
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        change(&servers)
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Codex (TOML)

    /// Codex's config is TOML that users edit by hand: no full re-serialisation.
    /// Only the `[mcp_servers.atlas]` table (and its sub-tables) is replaced.
    static func codexConnect(_ text: String, executable: String) -> String {
        let block = """
        [mcp_servers.atlas]
        command = \(tomlString(executable))
        args = []
        """
        let cleaned = codexDisconnect(text)
        let base = cleaned.hasSuffix("\n") || cleaned.isEmpty ? cleaned : cleaned + "\n"
        return base + (base.isEmpty ? "" : "\n") + block + "\n"
    }

    static func codexDisconnect(_ text: String) -> String {
        var out: [Substring] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                skipping = t == "[mcp_servers.atlas]" || t.hasPrefix("[mcp_servers.atlas.")
            }
            if !skipping { out.append(line) }
        }
        // Collapse the blank lines a removed block leaves behind.
        var result = out.joined(separator: "\n")
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        if result.hasSuffix("\n\n") { result.removeLast() }
        return result
    }

    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Files

    private static func backUp(_ url: URL, _ existing: String?) {
        guard let existing else { return }
        let backup = url.appendingPathExtension("atlas-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? existing.write(to: backup, atomically: true, encoding: .utf8)
        }
    }

    private static func write(_ text: String, to url: URL, keepingModeOf original: URL?) throws {
        let mode = original.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? Int }
        try text.write(to: url, atomically: true, encoding: .utf8)
        // Config files often hold tokens: keep them private (e.g. 0600).
        try? FileManager.default.setAttributes([.posixPermissions: mode ?? 0o600], ofItemAtPath: url.path)
    }
}
