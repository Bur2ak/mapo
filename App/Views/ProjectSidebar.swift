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
                        ProjectRow(project: project)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name)
                .lineLimit(1)
            Text(abbreviatedPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
        .help(project.rootPath)
    }

    private var abbreviatedPath: String {
        (project.rootPath as NSString).abbreviatingWithTildeInPath
    }
}
