import Foundation
import Testing
@testable import MapoCore

@Suite("MCP sunucusu")
struct MCPServerTests {
    private func server() throws -> (MCPServer, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-mcp-\(UUID().uuidString)")
        let paths = MapoPaths(base: base)
        let id = UUID()
        try FileManager.default.createDirectory(at: paths.graphFile(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixture = try #require(Bundle.module.url(forResource: "kucuk", withExtension: "json", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: paths.graphFile(id))
        let lib = """
        {"version":1,"projects":[{"id":"\(id.uuidString)","name":"deneme","rootPath":"/tmp/deneme","addedAt":"2026-10-07T00:00:00Z","source":{"folder":{}},
         "lastIndex":{"finishedAt":"2026-10-07T00:00:00Z","commit":"abc1234def","nodeCount":11,"edgeCount":12,"fileCount":3}}]}
        """
        try Data(lib.utf8).write(to: paths.libraryFile)
        return (MCPServer(paths: paths, version: "test"), base)
    }

    private func rpc(_ s: MCPServer, _ method: String, _ params: [String: Any] = [:], id: Int = 1) throws -> [String: Any] {
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: msg), as: UTF8.self)
        let reply = try #require(s.handle(line: line))
        return try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    private func tool(_ s: MCPServer, _ name: String, _ args: [String: Any]) throws -> (String, Bool) {
        let r = try rpc(s, "tools/call", ["name": name, "arguments": args])
        let result = try #require(r["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    @Test func handshakeAndToolList() throws {
        let (s, _) = try server()
        let init_ = try rpc(s, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        let result = try #require(init_["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == MCPServer.protocolVersion)
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        let tools = try #require((try rpc(s, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == 9)
        for t in tools {
            let schema = try #require(t["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect((t["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        }
    }

    @Test func conformanceDetails() throws {
        let (s, _) = try server()
        let old = try rpc(s, "initialize", ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        #expect((old["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-03-26")
        let future = try rpc(s, "initialize", ["protocolVersion": "2099-01-01", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        #expect((future["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.protocolVersion)
        #expect(try #require(s.handle(line: "[1,2]")).contains("-32600"))
        #expect(try #require(s.handle(line: #"{"jsonrpc":"2.0","id":9}"#)).contains("-32600"))
        let unknown = try rpc(s, "tools/call", ["name": "yok_boyle", "arguments": [:]])
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    @Test func approximateMatchesAreFlagged() throws {
        let (s, _) = try server()
        let (fuzzy, _) = try tool(s, "mapo_callers", ["project": "deneme", "symbol": "kulupSohbet"])
        #expect(fuzzy.hasPrefix("note: approximate match"))
        let (exact, _) = try tool(s, "mapo_callers", ["project": "deneme", "symbol": "kulupSohbetiAc"])
        #expect(!exact.contains("approximate"))
    }

    @Test func notificationsGetNoReply() throws {
        let (s, _) = try server()
        #expect(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func protocolErrors() throws {
        let (s, _) = try server()
        let bad = try #require(s.handle(line: "{bozuk"))
        #expect(bad.contains("-32700"))
        let unknown = try rpc(s, "yok/boyle")
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func callersAndPathWithLocations() throws {
        let (s, _) = try server()
        let (callers, e1) = try tool(s, "mapo_callers", ["project": "deneme", "symbol": "kulupSohbetiAc"])
        #expect(!e1)
        #expect(callers.contains("KulupSayfasi"))
        #expect(callers.contains("apps/mobile/app/kulupler/[id].tsx:40"))
        #expect(callers.contains("freshness:") && callers.contains("abc1234"))

        let (path, _) = try tool(s, "mapo_path", ["project": "deneme", "from": "KulupSayfasi", "to": "istek"])
        let order = ["KulupSayfasi", "kulupSohbetiAc", "kulupOzelSohbetAc", "istek"].compactMap { path.range(of: $0)?.lowerBound }
        #expect(order.count == 4 && order == order.sorted())
    }

    @Test func fileDependenciesAndImpact() throws {
        let (s, _) = try server()
        let (deps, _) = try tool(s, "mapo_file_dependencies", ["project": "deneme", "path": "kulupSohbet.ts"])
        #expect(deps.contains("Uses:\n  apps/mobile/lib/api.ts  ×2"))
        let (impact, _) = try tool(s, "mapo_impact", ["project": "deneme", "symbol": "istek", "depth": 2])
        #expect(impact.contains("Distance 1") && impact.contains("kulupOzelSohbetAc"))
        #expect(impact.contains("Distance 2") && impact.contains("kulupSohbetiAc"))
    }

    @Test func endpointsAndBridgedNode() throws {
        let (s, base) = try server()
        let (none, _) = try tool(s, "mapo_endpoints", ["project": "deneme"])
        #expect(none.contains("No HTTP endpoints"))
        // A bridges file beside graph.json (written by the app after indexing).
        let lib = try String(contentsOf: base.appendingPathComponent("library.json"), encoding: .utf8)
        let at = try #require(lib.range(of: #"[0-9A-F-]{36}"#, options: .regularExpression)).lowerBound
        let dir = MapoPaths(base: base).graphFile(UUID(uuidString: String(lib[at...].prefix(36)))!).deletingLastPathComponent()
        let bridges = """
        {"nodes":[{"id":"mapo:route:POST /api/kulup/:id/sohbet","label":"POST /api/kulup/:id/sohbet","type":"route","source_file":"apps/api/src/routes/kulup.ts","source_location":"L40"},
                  {"id":"mapo:table:kulupler","label":"kulupler","type":"table","source_file":"apps/api/migrations/0001.sql","source_location":"L3"}],
         "links":[{"source":"fn_ozel","target":"mapo:route:POST /api/kulup/:id/sohbet","relation":"requests","confidence":"INFERRED"},
                  {"source":"m_oda","target":"mapo:table:kulupler","relation":"writes","confidence":"INFERRED"}]}
        """
        try Data(bridges.utf8).write(to: dir.appendingPathComponent(Bridges.fileName))
        // The running server picks the new bridges up (no restart).
        let fresh = s
        let (eps, _) = try tool(fresh, "mapo_endpoints", ["project": "deneme"])
        #expect(eps.contains("route POST /api/kulup/:id/sohbet  apps/api/src/routes/kulup.ts:40  ← 1 caller: kulupOzelSohbetAc"))
        #expect(eps.contains("table kulupler") && eps.contains("written by 1"))
        let (filtered, _) = try tool(fresh, "mapo_endpoints", ["project": "deneme", "query": "zzz"])
        #expect(filtered.contains("No endpoint or table matches"))
        let (node, _) = try tool(fresh, "mapo_node", ["project": "deneme", "symbol": "kulupOzelSohbetAc"])
        #expect(node.contains("Requests (1):") && node.contains("POST /api/kulup/:id/sohbet"))
    }

    @Test func singleProjectNeedsNoName() throws {
        let (s, _) = try server()
        let (text, isError) = try tool(s, "mapo_search", ["query": "istek"])
        #expect(!isError && text.contains("istek"))
    }

    @Test func toolErrorsAreReadable() throws {
        let (s, _) = try server()
        let (a, e1) = try tool(s, "mapo_node", ["project": "olmayan", "symbol": "x"])
        #expect(e1 && a.contains("deneme"))
        let (b, e2) = try tool(s, "mapo_callers", ["project": "deneme"])
        #expect(e2 && b.contains("symbol"))
        let (c, e3) = try tool(s, "mapo_callers", ["project": "deneme", "symbol": "zzqqxx"])
        #expect(e3 && c.contains("mapo_search"))
    }

    @Test func mapRebuildIsPickedUp() throws {
        let (s, base) = try server()
        _ = try tool(s, "mapo_search", ["query": "istek"])
        let lib = try String(contentsOf: base.appendingPathComponent("library.json"), encoding: .utf8)
        let id = try #require(lib.range(of: #"[0-9A-F-]{36}"#, options: .regularExpression)).lowerBound
        let uuid = String(lib[id...].prefix(36))
        let graphURL = MapoPaths(base: base).graphFile(UUID(uuidString: uuid)!)
        var json = try String(contentsOf: graphURL, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"istek()\"", with: "\"yeniIstek()\"")
        try json.write(to: graphURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: graphURL.path)
        let (text, _) = try tool(s, "mapo_search", ["query": "yeniIstek"])
        #expect(text.contains("yeniIstek"))
    }
}

@Suite("Ajan entegrasyonları")
struct AgentIntegrationTests {
    private func home() throws -> URL {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        return h
    }

    @Test func jsonClientsPreserveOtherSettings() throws {
        let h = try home()
        let url = h.appendingPathComponent(".claude.json")
        try Data(#"{"theme":"dark","mcpServers":{"linear":{"type":"http","url":"https://x"}},"projects":{"a":1}}"#.utf8).write(to: url)
        try AgentIntegrations.connect(.claudeCode, executable: "/Applications/Mapo.app/Contents/MacOS/mapo-mcp", home: h)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(obj["theme"] as? String == "dark")
        #expect((obj["projects"] as? [String: Any])?["a"] as? Int == 1)
        let servers = try #require(obj["mcpServers"] as? [String: Any])
        #expect(servers["linear"] != nil)
        #expect((servers["mapo"] as? [String: Any])?["command"] as? String == "/Applications/Mapo.app/Contents/MacOS/mapo-mcp")
        #expect(AgentIntegrations.isConnected(.claudeCode, home: h))
        #expect(FileManager.default.fileExists(atPath: url.path + ".mapo-backup"))

        try AgentIntegrations.disconnect(.claudeCode, home: h)
        #expect(!AgentIntegrations.isConnected(.claudeCode, home: h))
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((after["mcpServers"] as? [String: Any])?["linear"] != nil)
    }

    @Test func createsMissingConfig() throws {
        let h = try home()
        try AgentIntegrations.connect(.cursor, executable: "/x/mapo-mcp", home: h)
        #expect(AgentIntegrations.isConnected(.cursor, home: h))
        let mode = try FileManager.default.attributesOfItem(atPath: h.appendingPathComponent(".cursor/mcp.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func refusesToClobberBrokenJSON() throws {
        let h = try home()
        let url = h.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ bozuk".utf8).write(to: url)
        #expect(throws: AgentIntegrations.IntegrationError.self) {
            try AgentIntegrations.connect(.cursor, executable: "/x", home: h)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ bozuk")
    }

    @Test func codexTomlKeepsEverythingElse() throws {
        let original = """
        model = "gpt-5"
        service_tier = "default"

        [mcp_servers.linear]
        url = "https://mcp.linear.app/mcp"

        [mcp_servers.node_repl]
        command = "/Applications/Codex.app/Contents/Resources/node_repl"

        [mcp_servers.node_repl.env]
        A = "1"

        """
        let connected = try AgentIntegrations.codexConnect(original, executable: "/Applications/Mapo.app/Contents/MacOS/mapo-mcp")
        #expect(connected.hasPrefix(original.trimmingCharacters(in: .newlines)))
        #expect(connected.contains("[mcp_servers.mapo]\ncommand = \"/Applications/Mapo.app/Contents/MacOS/mapo-mcp\"\nargs = []"))
        // Re-connecting replaces, never duplicates.
        let twice = try AgentIntegrations.codexConnect(connected, executable: "/new/path")
        #expect(twice.components(separatedBy: "[mcp_servers.mapo]").count == 2)
        #expect(twice.contains("/new/path") && !twice.contains("/Applications/Mapo.app"))
        // Disconnect restores the original content.
        let removed = AgentIntegrations.codexDisconnect(twice)
        #expect(removed.trimmingCharacters(in: .newlines) == original.trimmingCharacters(in: .newlines))
        #expect(removed.contains("[mcp_servers.node_repl.env]\nA = \"1\""))
    }

    @Test func codexMapoSubtablesRemoved() {
        let text = "[mcp_servers.mapo]\ncommand = \"x\"\n\n[mcp_servers.mapo.env]\nK = \"v\"\n\n[other]\na = 1\n"
        let out = AgentIntegrations.codexDisconnect(text)
        #expect(!out.contains("mapo"))
        #expect(out.contains("[other]\na = 1"))
    }

    @Test func tomlEscaping() {
        #expect(AgentIntegrations.tomlString(#"/a "b"\c"#) == #""/a \"b\"\\c""#)
    }
}

/// Prints real MCP answers for docs: `MAPO_MCP_DEMO=<data dir> swift test --filter mcpDemo`
@Test func mcpDemo() throws {
    guard let dir = ProcessInfo.processInfo.environment["MAPO_MCP_DEMO"] else { return }
    let s = MCPServer(paths: MapoPaths(base: URL(fileURLWithPath: dir)), version: "demo")
    for (tool, args) in [("mapo_node", ["symbol": "orders"]), ("mapo_endpoints", ["query": "/api/"]), ("mapo_impact", ["symbol": "saveOrder", "depth": 2] as [String: Any])] {
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": args]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: msg), as: UTF8.self)
        let reply = try JSONSerialization.jsonObject(with: Data(s.handle(line: line)!.utf8)) as! [String: Any]
        let text = (((reply["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String)
        print("=== \(tool)\n\(text)")
    }
}
