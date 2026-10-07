import AppKit
import SwiftUI

@main
struct AtlasApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Atlas", id: "main") {
            ContentView()
                .environment(model)
                .task { await model.start() }
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Klasör Ekle…") { FolderPicker.present(model: model) }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// "Klasör Ekle…" panel, shared by the menu command and the sidebar button.
@MainActor
enum FolderPicker {
    static func present(model: AppModel) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Proje klasörü seç")
        panel.prompt = String(localized: "Ekle")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await model.addFolders(urls) }
    }
}
