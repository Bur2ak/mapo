import Foundation
import Testing
@testable import MapoCore

@Suite("Atlas → Mapo geçişi")
struct MigrationTests {
    private func support() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func movesLegacyDataFolder() throws {
        let s = try support()
        let legacy = s.appendingPathComponent("Atlas")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("Projects/x"), withIntermediateDirectories: true)
        try Data("{\"version\":1,\"projects\":[]}".utf8).write(to: legacy.appendingPathComponent("library.json"))
        let paths = MapoPaths(base: s.appendingPathComponent("Mapo"))
        #expect(LegacyMigration.moveDataFolder(to: paths))
        #expect(FileManager.default.fileExists(atPath: paths.libraryFile.path))
        #expect(FileManager.default.fileExists(atPath: paths.base.appendingPathComponent("Projects/x").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        // Second run: nothing to do.
        #expect(!LegacyMigration.moveDataFolder(to: paths))
    }

    @Test func clonedRepoPathsFollowTheMove() throws {
        let s = try support()
        let legacy = s.appendingPathComponent("Atlas")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("Repos/o/r"), withIntermediateDirectories: true)
        let lib = """
        {"version":1,"projects":[{"id":"\(UUID().uuidString)","name":"r","rootPath":"\(legacy.path)/Repos/o/r","addedAt":"2026-10-07T00:00:00Z","source":{"github":{"owner":"o","repo":"r"}}},
         {"id":"\(UUID().uuidString)","name":"k","rootPath":"/Users/x/kontak","addedAt":"2026-10-07T00:00:00Z","source":{"folder":{}}}]}
        """
        try Data(lib.utf8).write(to: legacy.appendingPathComponent("library.json"))
        let paths = MapoPaths(base: s.appendingPathComponent("Mapo"))
        #expect(LegacyMigration.moveDataFolder(to: paths))
        let text = try String(contentsOf: paths.libraryFile, encoding: .utf8)
        #expect(text.contains("\(paths.base.path)/Repos/o/r"))
        #expect(text.contains("/Users/x/kontak"))
        #expect(!text.contains("/Atlas/"))
    }

    @Test func neverOverwritesExistingMapoData() throws {
        let s = try support()
        let legacy = s.appendingPathComponent("Atlas")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("eski".utf8).write(to: legacy.appendingPathComponent("library.json"))
        let paths = MapoPaths(base: s.appendingPathComponent("Mapo"))
        try FileManager.default.createDirectory(at: paths.base, withIntermediateDirectories: true)
        try Data("yeni".utf8).write(to: paths.libraryFile)
        #expect(!LegacyMigration.moveDataFolder(to: paths))
        #expect(try String(contentsOf: paths.libraryFile, encoding: .utf8) == "yeni")
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func replacesEmptyMapoFolder() throws {
        let s = try support()
        let legacy = s.appendingPathComponent("Atlas")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("library.json"))
        let paths = MapoPaths(base: s.appendingPathComponent("Mapo"))
        try FileManager.default.createDirectory(at: paths.base, withIntermediateDirectories: true)
        #expect(LegacyMigration.moveDataFolder(to: paths))
        #expect(FileManager.default.fileExists(atPath: paths.libraryFile.path))
    }

    @Test func keychainItemMoves() throws {
        let tag = UUID().uuidString
        let old = Keychain(service: LegacyMigration.legacyBundleID)
        let new = Keychain(service: "io.github.bur2ak.mapo.tests-\(tag)")
        let account = "test-\(tag)"
        defer { try? old.delete(account: account); try? new.delete(account: account) }
        try old.set(Data("token".utf8), account: account)
        LegacyMigration.moveKeychainItem(account: account, to: new)
        #expect(try new.get(account: account) == Data("token".utf8))
        #expect(try old.get(account: account) == nil)
    }

    @Test func connectingRemovesLegacyAgentEntries() throws {
        let h = try support()
        let claude = h.appendingPathComponent(".claude.json")
        try Data(#"{"mcpServers":{"atlas":{"command":"/old/atlas-mcp"},"linear":{"url":"x"}}}"#.utf8).write(to: claude)
        try AgentIntegrations.connect(.claudeCode, executable: "/Applications/Mapo.app/Contents/MacOS/mapo-mcp", home: h)
        let servers = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: claude)) as? [String: Any])?["mcpServers"] as? [String: Any])
        #expect(servers["atlas"] == nil && servers["mapo"] != nil && servers["linear"] != nil)

        let codex = "model = \"x\"\n\n[mcp_servers.atlas]\ncommand = \"/old\"\nargs = []\n\n[mcp_servers.linear]\nurl = \"u\"\n"
        let out = try AgentIntegrations.codexConnect(AgentIntegrations.codexRemove(codex, name: "atlas"), executable: "/new/mapo-mcp")
        #expect(!out.contains("mcp_servers.atlas") && out.contains("[mcp_servers.mapo]") && out.contains("[mcp_servers.linear]"))
    }
}
