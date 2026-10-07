import AtlasCore
import Foundation

// atlas-mcp — Atlas's MCP server for coding agents (stdio).
// Spawned by Claude Code / Codex / Cursor / Claude Desktop; reads the maps the
// Atlas app keeps in ~/Library/Application Support/Atlas. Read-only, no network.

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
if args.contains("--version") {
    print("atlas-mcp \(MCPServer.protocolVersion)")
    exit(0)
}
var paths = AtlasPaths.standard
if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
    paths = AtlasPaths(base: URL(fileURLWithPath: args[i + 1], isDirectory: true))
}
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
MCPServer(paths: paths, version: version).run()
