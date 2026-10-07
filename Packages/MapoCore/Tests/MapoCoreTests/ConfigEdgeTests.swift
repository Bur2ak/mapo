import Foundation
import Testing
@testable import MapoCore

/// Edge cases from the external review (7 Oct 2026): agents' config files
/// must never be corrupted or silently replaced.
@Suite("Ayar dosyası uç durumları")
struct ConfigEdgeTests {
    private func home() throws -> URL {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        return h
    }

    private let exe = "/Applications/Mapo.app/Contents/MacOS/mapo-mcp"

    @Test func crlfIsHandledAndPreserved() throws {
        let original = "model = \"x\"\r\n\r\n[mcp_servers.mapo]\r\ncommand = \"/old\"\r\n\r\n[mcp_servers.linear]\r\nurl = \"u\"\r\n"
        let out = try AgentIntegrations.codexConnect(original, executable: "/new")
        #expect(out.components(separatedBy: "[mcp_servers.mapo]").count == 2)
        #expect(!out.contains("/old") && out.contains("/new"))
        #expect(!out.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(out.contains("[mcp_servers.linear]\r\nurl"))
    }

    @Test func quotedSpacedAndCommentedHeaders() throws {
        let text = "[ mcp_servers.\"mapo\" ] # not\ncommand = \"/old\"\n\n[other]\na = 1\n"
        #expect(TOMLDoc(text).commandOfTable(named: "mapo") == "/old")
        let out = try AgentIntegrations.codexConnect(text, executable: "/new")
        #expect(!out.contains("/old"))
        #expect(out.contains("[other]\na = 1"))
        #expect(out.components(separatedBy: "mapo").count == 2)
    }

    @Test func headerInsideMultilineStringIsNotATable() throws {
        let text = "note = '''\n[mcp_servers.mapo]\n'''\nother = 1\n"
        let out = try AgentIntegrations.codexConnect(text, executable: "/new")
        #expect(out.hasPrefix("note = '''\n[mcp_servers.mapo]\n'''\nother = 1"))
        #expect(TOMLDoc(text).commandOfTable(named: "mapo") == nil)
    }

    @Test func refusesInlineAndDottedDeclarations() {
        let inline = "[mcp_servers]\nmapo = { command = \"/x\" }\n"
        #expect(throws: AgentIntegrations.IntegrationError.self) { try AgentIntegrations.codexConnect(inline, executable: "/new") }
        let dotted = "mcp_servers.mapo.command = \"/x\"\n"
        #expect(throws: AgentIntegrations.IntegrationError.self) { try AgentIntegrations.codexConnect(dotted, executable: "/new") }
        // Other servers declared inline are fine.
        let other = "[mcp_servers]\nlinear = { url = \"u\" }\n"
        #expect((try? AgentIntegrations.codexConnect(other, executable: "/new")) != nil)
    }

    @Test func unreadableConfigIsNeverOverwritten() throws {
        let h = try home()
        let url = h.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let notUTF8 = Data([0x6D, 0x3D, 0x22, 0xFE, 0x22, 0x0A])
        try notUTF8.write(to: url)
        #expect(throws: AgentIntegrations.IntegrationError.self) {
            try AgentIntegrations.connect(.codex, executable: exe, home: h)
        }
        #expect(try Data(contentsOf: url) == notUTF8)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".mapo-backup"))
    }

    @Test func nonObjectMcpServersIsRefused() throws {
        let h = try home()
        let url = h.appendingPathComponent(".claude.json")
        try Data(#"{"mcpServers": []}"#.utf8).write(to: url)
        #expect(throws: AgentIntegrations.IntegrationError.self) { try AgentIntegrations.connect(.claudeCode, executable: exe, home: h) }
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"mcpServers": []}"#)
    }

    @Test func writesThroughSymlinkAndBackupIsPrivate() throws {
        let h = try home()
        let real = h.appendingPathComponent("dotfiles/config.toml")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"x\"\n".utf8).write(to: real)
        let link = h.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try AgentIntegrations.connect(.codex, executable: exe, home: h)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8).contains("[mcp_servers.mapo]"))
        let mode = try FileManager.default.attributesOfItem(atPath: real.resolvingSymlinksInPath().path + ".mapo-backup")[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func refusesUnstableLocationsAndReportsOutdated() throws {
        let h = try home()
        #expect(throws: AgentIntegrations.IntegrationError.unstableLocation) {
            try AgentIntegrations.connect(.cursor, executable: "/Volumes/Mapo 0.1.0/Mapo.app/Contents/MacOS/mapo-mcp", home: h)
        }
        #expect(!AgentIntegrations.isStableExecutable("/private/var/folders/x/AppTranslocation/ABC/d/Mapo.app/Contents/MacOS/mapo-mcp"))
        try AgentIntegrations.connect(.cursor, executable: exe, home: h)
        #expect(AgentIntegrations.status(.cursor, executable: exe, home: h) == .connected)
        #expect(AgentIntegrations.status(.cursor, executable: "/Users/x/Mapo.app/Contents/MacOS/mapo-mcp", home: h) == .outdated(command: exe))
        #expect(AgentIntegrations.isConnected(.cursor, home: h))
    }
}
