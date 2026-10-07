import AtlasCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var tab = UserDefaults.standard.string(forKey: "atlasSettingsTab") ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("Genel", systemImage: "gearshape") }
                .tag("general")
            IntegrationsSettings()
                .tabItem { Label("Entegrasyonlar", systemImage: "puzzlepiece.extension") }
                .tag("integrations")
            AboutSettings()
                .tabItem { Label("Hakkında", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("editor") private var editorRaw = Editor.preferred.rawValue
    @AppStorage("menuBarIcon") private var menuBarIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Hesaplar") {
                GitHubAccountRow()
            }
            Section {
                Toggle(isOn: $model.autoUpdate) {
                    Text("Haritaları kendiliğinden güncelle")
                    Text("Kod değiştiğinde, commit atıldığında ya da dal değiştiğinde haritası olan projeler arka planda yeniden analiz edilir.")
                }
            }
            Section {
                Picker("Dosyaları şununla aç", selection: $editorRaw) {
                    ForEach(Editor.installed) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section {
                Toggle("Menü çubuğunda göster", isOn: $menuBarIcon)
                Toggle(isOn: $launchAtLogin) {
                    Text("Oturum açılınca başlat")
                    if let loginError {
                        Text(loginError).foregroundStyle(Palette.error)
                    }
                }
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GitHubAccountRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LabeledContent {
            switch model.github.state {
            case .signedIn:
                Button("Bağlantıyı Kes", role: .destructive) { model.github.signOut() }
            case .signingIn:
                ProgressView().controlSize(.small)
            case .signedOut:
                Button("Bağlan…") { NotificationCenter.default.post(name: .showGitHubSheet, object: nil) }
            }
        } label: {
            Text("GitHub")
            switch model.github.state {
            case .signedIn(let user): Text("@\(user.login) olarak bağlı · token Anahtar Zinciri'nde")
            case .signingIn: Text("Onay bekleniyor…")
            case .signedOut: Text("Bağlı değil")
            }
        }
    }
}

private struct UpdatesRow: View {
    @State private var automatic = Updater.shared.automaticallyChecks

    var body: some View {
        if Updater.shared.isAvailable {
            Toggle("Güncellemeleri kendiliğinden denetle", isOn: $automatic)
                .onChange(of: automatic) { _, v in Updater.shared.automaticallyChecks = v }
            LabeledContent("") {
                Button("Şimdi Denetle") { Updater.shared.checkForUpdates() }
            }
        } else {
            LabeledContent("Güncellemeler", value: String(localized: "Geliştirme sürümünde kapalı"))
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        Form {
            LabeledContent("Sürüm", value: Bundle.main.shortVersion)
            UpdatesRow()
            LabeledContent("Gizlilik") {
                Text("Kodun bu Mac'ten çıkmaz. Atlas analiz verisi göndermez, telemetri toplamaz.")
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Analiz motoru") {
                Link("graphify (Apache-2.0 / MIT)", destination: URL(string: "https://github.com/Graphify-Labs/graphify")!)
            }
            LabeledContent("Günlükler") {
                Button("Finder'da Göster") {
                    let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Atlas")
                    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([logs])
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension Bundle {
    var shortVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
