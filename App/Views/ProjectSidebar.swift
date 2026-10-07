import AppKit
import AtlasCore
import SwiftUI

struct ProjectSidebar: View {
    @Environment(AppModel.self) private var model

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
                        ProjectRow(project: project, behind: model.behind[project.id])
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
                Button {
                    FolderPicker.present(model: model)
                } label: {
                    Label("Klasör Ekle", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Bir proje klasörü ekle (⌘O)")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func contextMenu(for project: Project) -> some View {
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
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .help(statusHelp)
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
