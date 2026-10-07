import AppKit
import MapoCore
import SwiftUI

struct ProjectSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var showGitHub = false

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if model.projects.isEmpty {
                Text("Henüz proje yok")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            } else {
                Section("Projeler") {
                    ForEach(model.projects) { project in
                        ProjectRow(project: project, behind: model.behind[project.id], indexing: model.indexer.status[project.id])
                            .tag(project.id)
                            .contextMenu { contextMenu(for: project) }
                    }
                    .onMove { source, destination in
                        Task { await model.move(fromOffsets: source, toOffset: destination) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Klasör Ekle…") { FolderPicker.present(model: model) }
                        .keyboardShortcut("o")
                    Button("GitHub'dan Ekle…") { showGitHub = true }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                } label: {
                    Label("Proje Ekle", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Klasör ya da GitHub reposu ekle")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showGitHub) {
            GitHubSheet().environment(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGitHubSheet)) { _ in showGitHub = true }
    }

    @ViewBuilder
    private func contextMenu(for project: Project) -> some View {
        if case .github(let owner, let repo) = project.source,
           let url = URL(string: "https://github.com/\(owner)/\(repo)") {
            Button("GitHub'da Aç") { NSWorkspace.shared.open(url) }
        }
        Button("Finder'da Göster") {
            NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
        }
        Divider()
        Button("Kütüphaneden Kaldır", role: .destructive) {
            Task { await model.remove(project.id) }
        }
    }
}

private struct ProjectRow: View {
    let project: Project
    let behind: Int?
    let indexing: IndexCoordinator.Status?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            switch indexing {
            case .queued, .running:
                ProgressView().controlSize(.mini).help("Harita güncelleniyor")
            case .failed(let message):
                Circle().fill(Palette.error).frame(width: 7, height: 7).help(message)
            case nil:
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .help(statusHelp)
            }
        }
        .padding(.vertical, 2)
        .help(project.rootPath)
    }

    private var detail: String {
        if let files = project.lastIndex?.fileCount {
            return String(localized: "\(files) dosya")
        }
        return (project.rootPath as NSString).abbreviatingWithTildeInPath
    }

    private var statusColor: Color {
        guard project.lastIndex != nil else { return Color.secondary.opacity(0.4) }
        switch behind {
        case 0: return Palette.fresh
        case .some: return Palette.stale
        case nil: return Color.secondary.opacity(0.6)
        }
    }

    private var statusHelp: String {
        guard project.lastIndex != nil else { return String(localized: "Henüz haritası yok") }
        switch behind {
        case 0: return String(localized: "Harita güncel")
        case let n?: return String(localized: "Harita \(n) commit geride")
        case nil: return String(localized: "Güncellik bilinmiyor")
        }
    }
}

extension Notification.Name {
    static let showGitHubSheet = Notification.Name("mapo.showGitHubSheet")
}
