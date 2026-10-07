import MapoCore
import SwiftUI

/// Ayarlar → Entegrasyonlar: let coding agents query Mapo's maps (MCP).
struct IntegrationsSettings: View {
    @State private var statuses: [AgentIntegrations.Client: AgentIntegrations.Status] = [:]
    @State private var error: String?
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var executable: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("mapo-mcp").path
    }

    var body: some View {
        Form {
            Section {
                ForEach(AgentIntegrations.Client.allCases) { client in
                    row(client)
                }
            } header: {
                Text("Kodlama ajanları")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bağlanan ajan haritayı sorgulayabilir: \"bunu kim çağırıyor\", \"bu dosya neye bağlı\", \"bu değişirse ne etkilenir\". Salt okunur; kod hiçbir yere gönderilmez.")
                    Text("Bağladıktan sonra ajanı yeniden başlat.")
                    if let error {
                        Text(error).foregroundStyle(Palette.error)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Elle kurulum") {
                LabeledContent("Komut") {
                    Text(executable)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func row(_ client: AgentIntegrations.Client) -> some View {
        let installed = client.isInstalled(home: home)
        let status = statuses[client] ?? .notConnected
        return LabeledContent {
            switch status {
            case .connected:
                HStack(spacing: 10) {
                    Label("Bağlı", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.fresh)
                        .labelStyle(.titleAndIcon)
                    Button("Kaldır") { apply { try AgentIntegrations.disconnect(client, home: home) } }
                }
            case .outdated:
                HStack(spacing: 10) {
                    Label("Eski konum", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.stale)
                        .labelStyle(.titleAndIcon)
                    Button("Güncelle") { apply { try AgentIntegrations.connect(client, executable: executable, home: home) } }
                }
            case .notConnected:
                Button("Bağla") { apply { try AgentIntegrations.connect(client, executable: executable, home: home) } }
                    .disabled(!installed)
            }
        } label: {
            Text(client.title)
            switch status {
            case .outdated(let command):
                Text("Başka bir Mapo kopyasına bağlı: \(command)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            default:
                Text(installed ? "~/\(client.configPath)" : String(localized: "Kurulu görünmüyor"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func apply(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        for c in AgentIntegrations.Client.allCases {
            statuses[c] = AgentIntegrations.status(c, executable: executable, home: home)
        }
    }
}
