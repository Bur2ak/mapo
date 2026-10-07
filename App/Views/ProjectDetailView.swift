import AtlasCore
import SwiftUI

/// Project workspace: the map, its toolbar, the inspector and the ⌘K palette.
struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @AppStorage("inspectorShown") private var inspectorShown = true

    var body: some View {
        let workspace = model.workspace(for: project)
        WorkspaceView(inspectorShown: $inspectorShown)
            .environment(workspace)
            .focusedSceneValue(workspace)
            .navigationTitle(project.name)
            .navigationSubtitle((project.rootPath as NSString).abbreviatingWithTildeInPath)
    }
}

private struct WorkspaceView: View {
    @Environment(Workspace.self) private var workspace
    @Binding var inspectorShown: Bool

    var body: some View {
        @Bindable var workspace = workspace
        ZStack(alignment: .top) {
            MapView(controller: workspace.map)
                .opacity(workspace.state == .ready ? 1 : 0)

            switch workspace.state {
            case .loading:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsIndex:
                NeedsIndexView()
            case .indexing(let phase):
                IndexingView(phase: phase)
            case .failed(let message):
                FailedView(message: message)
            case .ready:
                EmptyView()
            }

            if workspace.isSearchPresented {
                Color.black.opacity(0.001)
                    .onTapGesture { workspace.isSearchPresented = false }
                SearchPalette()
                    .padding(.top, 60)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: workspace.isSearchPresented)
        .background(Palette.canvas)
        .task { await workspace.open() }
        .inspector(isPresented: $inspectorShown) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 310, max: 440)
        }
        .toolbar { WorkspaceToolbar(inspectorShown: $inspectorShown) }
        .alert(
            "Harita güncellenemedi",
            isPresented: Binding(get: { workspace.lastIndexError != nil }, set: { if !$0 { workspace.lastIndexError = nil } })
        ) {
            Button("Tamam") { workspace.lastIndexError = nil }
        } message: {
            Text(workspace.lastIndexError ?? "")
        }
    }
}

private struct WorkspaceToolbar: ToolbarContent {
    @Environment(Workspace.self) private var workspace
    @Binding var inspectorShown: Bool

    var body: some ToolbarContent {
        @Bindable var map = workspace.map
        ToolbarItem(placement: .navigation) {
            FreshnessBadge()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Ayrıntı", selection: $map.detail) {
                ForEach(MapController.Detail.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Haritada ne kadar ayrıntı gösterilsin (⌘1 ⌘2 ⌘3)")
            .disabled(workspace.state != .ready)

            Menu {
                Picker("Renk", selection: $map.colorMode) {
                    ForEach(MapController.ColorMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Toggle("Testleri gizle", isOn: $map.hideTests)
                Divider()
                Button("Haritayı sığdır") { workspace.map.fit() }
                Button("Yeniden yerleştir") { workspace.map.relayout() }
            } label: {
                Label("Görünüm", systemImage: "slider.horizontal.3")
            }
            .disabled(workspace.state != .ready)

            Button {
                workspace.isSearchPresented.toggle()
            } label: {
                Label("Ara", systemImage: "magnifyingglass")
            }
            .help("Ara (⌘K)")
            .disabled(workspace.search == nil)

            Button {
                inspectorShown.toggle()
            } label: {
                Label("Denetçi", systemImage: "sidebar.trailing")
            }
            .help("Denetçiyi göster/gizle (⌥⌘0)")
        }
    }
}

/// "● Güncel · a1b2c3d" / "3 commit geride · Güncelle" / spinner while refreshing.
private struct FreshnessBadge: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 6) {
            if workspace.isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Güncelleniyor").foregroundStyle(.secondary)
            } else if workspace.graph != nil {
                Circle()
                    .fill(isFresh ? Palette.fresh : Palette.stale)
                    .frame(width: 7, height: 7)
                Text(statusText)
                if let commit = workspace.project.lastIndex?.commit {
                    Text(String(commit.prefix(7)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !isFresh {
                    Button("Güncelle") { workspace.index() }
                        .buttonStyle(.link)
                        .disabled(!workspace.canIndex)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .help(helpText)
    }

    private var isFresh: Bool { workspace.freshness.behind == 0 }

    private var statusText: LocalizedStringKey {
        switch workspace.freshness.behind {
        case 0: "Güncel"
        case let n?: "\(n) commit geride"
        case nil: "Durum bilinmiyor"
        }
    }

    private var helpText: String {
        guard let last = workspace.project.lastIndex else { return "" }
        let when = last.finishedAt.formatted(.relative(presentation: .named))
        return String(localized: "Son güncelleme \(when)")
    }
}

private struct NeedsIndexView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "map")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Palette.labelMuted)
            Text("Bu projenin henüz haritası yok")
                .font(.title3.weight(.semibold))
            if workspace.canIndex {
                Text("Kod yalnızca bu Mac'te analiz edilir. Büyük projelerde bir dakika sürebilir.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Haritayı Çıkar") { workspace.index() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                EngineMissingNote()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EngineMissingNote: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Analiz motoru bulunamadı. Bu geliştirme sürümü sistemde kurulu graphify'ı kullanıyor:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("uv tool install --python 3.12 graphifyy==0.9.79")
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: 420)
    }
}

private struct IndexingView: View {
    @Environment(Workspace.self) private var workspace
    let phase: Engine.Phase

    var body: some View {
        VStack(spacing: 14) {
            switch phase {
            case .extracting(let done, let total):
                ProgressView(value: Double(done), total: Double(total))
                    .frame(width: 260)
                Text("Kod okunuyor · \(done)/\(total) dosya")
            case .scanning:
                ProgressView().frame(width: 260)
                Text("Dosyalar taranıyor")
            case .clustering:
                ProgressView().frame(width: 260)
                Text("Modüller bulunuyor")
            case .finished:
                ProgressView().frame(width: 260)
                Text("Harita hazırlanıyor")
            }
            Button("Vazgeç") { workspace.cancelIndex() }
                .buttonStyle(.link)
        }
        .font(.callout)
        .monospacedDigit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailedView: View {
    @Environment(Workspace.self) private var workspace
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(Palette.error)
            Text("Harita oluşturulamadı")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 460)
            if workspace.canIndex {
                Button("Tekrar Dene") { workspace.index() }
            } else {
                EngineMissingNote()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
