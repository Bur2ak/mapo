import AppKit
import MapoCore
import SwiftUI

/// Menu bar extra: every project's map status at a glance.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.projects.isEmpty {
            Text("Henüz proje yok")
        }
        ForEach(model.projects) { project in
            Button {
                model.selection = project.id
                showWindow()
            } label: {
                Text("\(project.name) — \(status(project))")
            }
        }
        Divider()
        Button("Hepsini Güncelle") { model.indexAll() }
            .disabled(model.projects.allSatisfy { $0.lastIndex == nil })
        Toggle("Kendiliğinden Güncelle", isOn: Binding(get: { model.autoUpdate }, set: { model.autoUpdate = $0 }))
        Divider()
        Button("Mapo'ı Aç") { showWindow() }
            .keyboardShortcut("o")
        Button("Çıkış") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func status(_ p: Project) -> String {
        switch model.indexer.status[p.id] {
        case .queued: return String(localized: "sırada")
        case .running: return String(localized: "güncelleniyor…")
        case .failed: return String(localized: "güncellenemedi")
        case nil: break
        }
        guard p.lastIndex != nil else { return String(localized: "haritası yok") }
        switch model.behind[p.id] {
        case 0: return String(localized: "güncel")
        case let n?: return String(localized: "\(n) commit geride")
        case nil: return String(localized: "güncel")
        }
    }
}

/// Menu bar icon: the app's symbol, spinning dots while indexing.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(systemName: model.indexer.isBusy ? "arrow.triangle.2.circlepath" : "point.3.connected.trianglepath.dotted")
    }
}
