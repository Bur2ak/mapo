import MapoCore
import Foundation

// mapo-mcp — Mapo's MCP server for coding agents (stdio).
// Spawned by Claude Code / Codex / Cursor / Claude Desktop; reads the maps the
// Mapo app keeps in ~/Library/Application Support/Mapo. Read-only, no network.

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
if args.contains("--version") {
    print("mapo-mcp \(MCPServer.protocolVersion)")
    exit(0)
}
var paths = MapoPaths.standard
if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
    paths = MapoPaths(base: URL(fileURLWithPath: args[i + 1], isDirectory: true))
}
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
MCPServer(paths: paths, version: version).run()
