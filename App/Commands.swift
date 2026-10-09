import SwiftUI

/// "Harita" menu. Acts on the focused window's workspace.
struct MapCommands: Commands {
    @FocusedValue(Workspace.self) private var workspace
    @AppStorage("inspectorShown") private var inspectorShown = true

    var body: some Commands {
        CommandMenu("Harita") {
            Button("Ara…") { workspace?.isSearchPresented = true }
                .keyboardShortcut("k")
                .disabled(workspace?.search == nil)

            Button("Geri") { workspace?.goBack() }
                .keyboardShortcut("[")
                .disabled(workspace?.back.isEmpty ?? true)
            Button("İleri") { workspace?.goForward() }
                .keyboardShortcut("]")
                .disabled(workspace?.forward.isEmpty ?? true)
            Button("Üst Düzeye Çık") { workspace?.map.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(workspace?.state != .ready)

            Divider()

            Button("Seçileni Editörde Aç") {
                if let ws = workspace, let node = ws.selectedNode { Editor.open(node: node, in: ws) }
            }
            .keyboardShortcut(.return)
            .disabled(workspace?.selectedNode == nil)

            Button("Yol Bul…") {
                if let ws = workspace, let id = ws.selectedID, let p = ws.graph?.position(of: id) { ws.beginPath(from: p) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(workspace?.selectedNode == nil)

            Button("Etki Alanını Göster") {
                if let ws = workspace, let id = ws.selectedID, let p = ws.graph?.position(of: id) { ws.showImpact(of: p) }
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(workspace?.selectedNode == nil)

            Button("Mermaid Olarak Kopyala") { workspace?.copyMermaid() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(workspace?.mermaid == nil)

            Button("Görüntü Olarak Kaydet…") { Task { await workspace?.exportImage() } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(workspace?.state != .ready)

            Divider()

            Button("Haritayı Güncelle") { workspace?.index() }
                .keyboardShortcut("r")
                .disabled(workspace == nil || workspace?.isRefreshing == true || workspace?.canIndex != true)

            Divider()

            ForEach(MapController.Detail.allCases) { level in
                Button(level.title) { workspace?.map.detail = level }
                    .keyboardShortcut(KeyEquivalent(Character("\(level.rawValue + 1)")))
            }
            .disabled(workspace?.state != .ready)

            Divider()

            Button("Sığdır") { workspace?.map.fit() }
                .keyboardShortcut("0")
            Button("Yakınlaştır") { workspace?.map.zoom(1.5) }
                .keyboardShortcut("=")
            Button("Uzaklaştır") { workspace?.map.zoom(1 / 1.5) }
                .keyboardShortcut("-")
            Button("Vurguyu Temizle") {
                workspace?.clearOverlay()
            }
            .keyboardShortcut(.escape, modifiers: [.command])

            Divider()

            Button(inspectorShown ? "Denetçiyi Gizle" : "Denetçiyi Göster") { inspectorShown.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
    }
}
