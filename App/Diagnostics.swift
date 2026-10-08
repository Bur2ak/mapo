import AppKit
import MapoCore
import UniformTypeIdentifiers

/// "Save Diagnostics…": logs and environment in one zip the user can look
/// through and send themselves (PLAN §3.8). No source code, no maps, no tokens.
@MainActor
enum Diagnostics {
    static func save(model: AppModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Mapo-tanilama-\(Date.now.formatted(.iso8601.year().month().day())).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let summary = report(model: model)
        Task.detached(priority: .userInitiated) {
            do {
                try build(summary: summary, to: url)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                await MainActor.run { model.alert = AlertMessage(error: error) }
            }
        }
    }

    static func report(model: AppModel) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = [
            "Mapo \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(machine())",
            "Dil: \(Bundle.main.preferredLocalizations.first ?? "?") · Düşük Güç: \(ProcessInfo.processInfo.isLowPowerModeEnabled)",
            "Analiz motoru: \(Engine.locate()?.executable.path ?? "bulunamadı")",
            "Kendiliğinden güncelle: \(model.autoUpdate)",
            "",
            "Projeler (\(model.projects.count)):",
        ]
        for p in model.projects {
            let idx = p.lastIndex.map { "\($0.fileCount) dosya, \($0.nodeCount) düğüm, \($0.edgeCount) bağ, \($0.finishedAt.formatted(.iso8601)), motor \($0.engineVersion ?? "?")" } ?? "haritası yok"
            let kind: String = switch p.source {
            case .folder: "klasör"
            case .github: "GitHub"
            }
            lines.append("- \(kind) · \(idx) · durum: \(model.indexer.status[p.id].map { "\($0)" } ?? "boşta")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func build(summary: String, to url: URL) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Mapo-tanilama-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(summary.utf8).write(to: dir.appendingPathComponent("ozet.txt"))
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Mapo")
        if fm.fileExists(atPath: logs.path) {
            // The newest 20 logs are plenty and keep the zip small.
            let files = (try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let recent = files.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }.prefix(20)
            let target = dir.appendingPathComponent("gunlukler", isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for f in recent { try? fm.copyItem(at: f, to: target.appendingPathComponent(f.lastPathComponent)) }
        }
        try? fm.removeItem(at: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", dir.path, url.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func machine() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
