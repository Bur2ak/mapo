import MapoCore
import SwiftUI

/// Ayarlar → Entegrasyonlar: let coding agents query Mapo's maps (MCP).
struct IntegrationsSettings: View {
    @State private var connected: [AgentIntegrations.Client: Bool] = [:]
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
        let isOn = connected[client] ?? false
        return LabeledContent {
            if isOn {
                HStack(spacing: 10) {
                    Label("Bağlı", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.fresh)
                        .labelStyle(.titleAndIcon)
                    Button("Kaldır") { apply { try AgentIntegrations.disconnect(client, home: home) } }
                }
            } else {
                Button("Bağla") { apply { try AgentIntegrations.connect(client, executable: executable, home: home) } }
                    .disabled(!installed)
            }
        } label: {
            Text(client.title)
            Text(installed ? "~/\(client.configPath)" : String(localized: "Kurulu görünmüyor"))
                .font(.caption)
                .foregroundStyle(.secondary)
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
            connected[c] = AgentIntegrations.isConnected(c, home: home)
        }
    }
}
