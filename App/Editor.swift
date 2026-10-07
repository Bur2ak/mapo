import AppKit
import AtlasCore
import SwiftUI

/// Opens a file at a line in the user's editor.
///
/// Uses each editor's URL scheme, so nothing has to be on PATH (GUI apps
/// launched from the Dock do not see the shell's PATH).
enum Editor: String, CaseIterable, Identifiable {
    case vscode, cursor, zed, windsurf, xcode, sublime, finder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vscode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .zed: "Zed"
        case .windsurf: "Windsurf"
        case .xcode: "Xcode"
        case .sublime: "Sublime Text"
        case .finder: String(localized: "Varsayılan uygulama")
        }
    }

    var bundleIDs: [String] {
        switch self {
        case .vscode: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .zed: ["dev.zed.Zed", "dev.zed.Zed-Preview"]
        case .windsurf: ["com.exafunction.windsurf"]
        case .xcode: ["com.apple.dt.Xcode"]
        case .sublime: ["com.sublimetext.4", "com.sublimetext.3"]
        case .finder: []
        }
    }

    var appURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    var isInstalled: Bool { self == .finder || appURL != nil }

    static var installed: [Editor] { allCases.filter(\.isInstalled) }

    /// The user's choice if still installed, else the first installed editor.
    static var preferred: Editor {
        if let raw = UserDefaults.standard.string(forKey: "editor"), let e = Editor(rawValue: raw), e.isInstalled { return e }
        return installed.first ?? .finder
    }

    @MainActor
    static func open(node: Node, in workspace: Workspace) {
        guard let url = workspace.fileURL(for: node) else { return }
        preferred.open(url, line: node.line)
    }

    @MainActor
    func open(_ file: URL, line: Int?) {
        let line = max(1, line ?? 1)
        let path = file.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let link: URL? = switch self {
        case .vscode: URL(string: "vscode://file\(encoded):\(line):1")
        case .cursor: URL(string: "cursor://file\(encoded):\(line):1")
        case .windsurf: URL(string: "windsurf://file\(encoded):\(line):1")
        case .zed: URL(string: "zed://file\(encoded):\(line)")
        case .sublime: URL(string: "subl://open?url=file://\(encoded)&line=\(line)")
        case .xcode, .finder: nil
        }
        if let link, NSWorkspace.shared.urlForApplication(toOpen: link) != nil {
            NSWorkspace.shared.open(link)
            return
        }
        if self == .xcode, let app = appURL {
            // xed is the only way to pass a line to Xcode.
            let xed = URL(fileURLWithPath: "/usr/bin/xed")
            if FileManager.default.isExecutableFile(atPath: xed.path) {
                let p = Process()
                p.executableURL = xed
                p.arguments = ["--line", "\(line)", path]
                if (try? p.run()) != nil { return }
            }
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSWorkspace.shared.open(file)
    }
}
