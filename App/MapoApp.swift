import MapoCore
import AppKit
import SwiftUI

@main
struct MapoApp: App {
    @State private var model = AppModel(paths: Self.dataPaths)
    @AppStorage("menuBarIcon") private var menuBarIcon = true

    /// DEBUG: `-mapoDataDir <path>` keeps tests away from the real library.
    private static var dataPaths: MapoPaths {
        #if DEBUG
        if let dir = UserDefaults.standard.string(forKey: "mapoDataDir") {
            return MapoPaths(base: URL(fileURLWithPath: dir, isDirectory: true))
        }
        #endif
        // Early users installed the app as "Atlas": bring their data along.
        LegacyMigration.moveDataFolder(to: .standard)
        LegacyMigration.copyDefaults(keys: [
            "lastProject", "autoUpdate", "editor", "menuBarIcon", "inspectorShown", "mapHintDismissed", "githubLogin",
        ])
        return .standard
    }

    var body: some Scene {
        Window("Mapo", id: "main") {
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
                Button("GitHub'dan Ekle…") { NotificationCenter.default.post(name: .showGitHubSheet, object: nil) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Mapo'ya Hoş Geldin") { model.showOnboarding = true }
                Button("Örnek Projeyi Aç") { Task { await model.openSample() } }
                Divider()
                Button("Geri Bildirim Gönder…") { Feedback.open() }
            }
            UpdaterCommands()
            MapCommands()
            InspectorCommands()
        }

        Window("Üçüncü Taraf Lisansları", id: "notices") {
            NoticesView()
        }
        .defaultSize(width: 680, height: 620)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: $menuBarIcon) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel()
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
