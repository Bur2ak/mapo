import MapoCore
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
    }
}

private struct WorkspaceView: View {
    @Environment(Workspace.self) private var workspace
    @Binding var inspectorShown: Bool
    @State private var levelNote: String?
    @State private var levelNoteTask: Task<Void, Never>?

    /// Switching level on a zoomed-out map can look like nothing happened:
    /// say what is now on the map, briefly.
    private func showLevelNote(_ level: MapController.Detail) {
        guard let g = workspace.graph else { return }
        let files = g.nodes.count { $0.kind == .file }
        let code = g.nodes.count { $0.kind == .function || $0.kind == .method || $0.kind == .type }
        // Exactly what the map draws at "All": files, code, constants (no
        // external packages or package.json dependencies).
        let all = g.nodes.count { $0.kind != .external && $0.kind != .document }
        let text: String = switch level {
        case .files: String(localized: "\(files) dosya")
        case .symbols: String(localized: "\(files) dosya + \(code) fonksiyon ve tip · adlar yakınlaştıkça görünür")
        case .everything: String(localized: "\(all) öğe · sabitler ve değişkenler dahil")
        }
        withAnimation(.easeOut(duration: 0.15)) { levelNote = text }
        levelNoteTask?.cancel()
        levelNoteTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { levelNote = nil }
        }
    }

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

        }
        // Overlay, not a ZStack sibling: the palette must never take part in
        // layout (as a sibling its fixed width pushed the split view sideways).
        .overlay(alignment: .top) {
            if workspace.isSearchPresented {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { workspace.cancelPath(); workspace.isSearchPresented = false }
                    SearchPalette()
                        .padding(.top, 60)
                        .padding(.horizontal, 24)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if workspace.state == .ready { ZoomControls().padding(14) }
        }
        .overlay(alignment: .bottom) {
            if workspace.state == .ready {
                VStack(spacing: 8) {
                    if let toast = workspace.toast { LevelNote(text: toast) }
                    if let note = levelNote { LevelNote(text: note) }
                    MapHint()
                }
                .padding(.bottom, 16)
            }
        }
        .onChange(of: workspace.map.detail) { _, level in showLevelNote(level) }
        .navigationSubtitle(statusLine)
        .animation(.easeOut(duration: 0.14), value: workspace.isSearchPresented)
        .animation(.easeOut(duration: 0.15), value: workspace.toast)
        .background(Palette.canvas)
        .task { await workspace.open() }
        .inspector(isPresented: $inspectorShown) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 310, max: 440)
        }
        .toolbar { WorkspaceToolbar(inspectorShown: $inspectorShown) }
    }
}

extension WorkspaceView {
    /// "Güncel · 4270de4" / "3 commit geride" / "Güncelleniyor…" under the title.
    var statusLine: String {
        if workspace.isRefreshing { return String(localized: "Harita güncelleniyor…") }
        if workspace.isDeferred { return String(localized: "Düşük Güç modu: güncelleme bekliyor") }
        if workspace.lastIndexError != nil { return String(localized: "Son güncelleme başarısız") }
        guard workspace.graph != nil else { return (workspace.project.rootPath as NSString).abbreviatingWithTildeInPath }
        let commit = workspace.project.lastIndex?.commit.map { " · " + $0.prefix(7) } ?? ""
        switch workspace.freshness.behind {
        case 0: return String(localized: "Güncel") + commit
        case let n?: return String(localized: "\(n) commit geride") + commit
        case nil:
            // Not a git repository: say when the map was made instead of a long path.
            guard let at = workspace.project.lastIndex?.finishedAt else {
                return (workspace.project.rootPath as NSString).abbreviatingWithTildeInPath
            }
            return String(localized: "Harita: \(at.formatted(.relative(presentation: .named)))")
        }
    }
}

private struct WorkspaceToolbar: ToolbarContent {
    @Environment(Workspace.self) private var workspace
    @Binding var inspectorShown: Bool

    var body: some ToolbarContent {
        @Bindable var map = workspace.map
        ToolbarItemGroup(placement: .navigation) {
            Button { workspace.goBack() } label: { Label("Geri", systemImage: "chevron.left") }
                .help("Önceki seçim (⌘[)")
                .disabled(workspace.back.isEmpty)
            Button { workspace.goForward() } label: { Label("İleri", systemImage: "chevron.right") }
                .help("Sonraki seçim (⌘])")
                .disabled(workspace.forward.isEmpty)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            UpdateButton()

            // Two levels people switch between; constants are a View option.
            Picker("Ayrıntı", selection: Binding(
                get: { map.detail == .files ? MapController.Detail.files : .symbols },
                set: { map.detail = $0 == .files ? .files : (map.detail == .everything ? .everything : .symbols) }
            )) {
                Text(MapController.Detail.files.title).tag(MapController.Detail.files)
                Text(MapController.Detail.symbols.title).tag(MapController.Detail.symbols)
            }
            .pickerStyle(.segmented)
            .help("Dosyalar: yalnız dosyalar · Kod: fonksiyonlar, tipler, uç noktalar ve tablolar (⌘1 ⌘2)")
            .disabled(workspace.state != .ready)

            Menu {
                Picker("Görünüm", selection: $map.style) {
                    ForEach(MapController.Style.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Renk", selection: $map.colorMode) {
                    ForEach(MapController.ColorMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Bağlantılar", selection: $map.linkFilter) {
                    ForEach(MapController.LinkFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Sabitleri ve değişkenleri göster", isOn: Binding(
                    get: { map.detail == .everything },
                    set: { map.detail = $0 ? .everything : .symbols }
                ))
                Toggle("Testleri gizle", isOn: $map.hideTests)
                Toggle("Yapılandırma ve derleme dosyalarını göster", isOn: $map.showNoise)
                Divider()
                Button("Haritayı sığdır") { workspace.map.fit() }
                if map.style == .network {
                    Button("Yeniden yerleştir") { workspace.map.relayout() }
                }
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

/// Refresh the map. Marked when the map is behind, spins while working.
private struct UpdateButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button {
            workspace.index()
        } label: {
            if workspace.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Label("Güncelle", systemImage: "arrow.triangle.2.circlepath")
                    .overlay(alignment: .topTrailing) {
                        if workspace.lastIndexError != nil {
                            Circle().fill(Palette.error).frame(width: 7, height: 7).offset(x: 3, y: -2)
                        } else if isStale {
                            Circle().fill(Palette.stale).frame(width: 7, height: 7).offset(x: 3, y: -2)
                        }
                    }
            }
        }
        .help(helpText)
        .disabled(workspace.isRefreshing || !workspace.canIndex || workspace.graph == nil)
    }

    private var isStale: Bool { (workspace.freshness.behind ?? 0) > 0 }

    private var helpText: String {
        if let error = workspace.lastIndexError {
            return String(localized: "Son güncelleme başarısız: \(error)\nTekrar denemek için tıkla (⌘R).")
        }
        return isStale ? String(localized: "Harita güncel değil, güncelle (⌘R)") : String(localized: "Haritayı güncelle (⌘R)")
    }
}

/// + / − / fit, bottom right of the map.
private struct ZoomControls: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            control("plus", "Yakınlaştır (⌘+)") { workspace.map.zoom(1.5) }
            Divider().frame(width: 18)
            control("minus", "Uzaklaştır (⌘−)") { workspace.map.zoom(1 / 1.5) }
            Divider().frame(width: 18)
            control("arrow.down.right.and.arrow.up.left", "Sığdır (⌘0)") { workspace.map.fit() }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func control(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct LevelNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .monospacedDigit()
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// One-time hint about map gestures; dismissed on click or after a while.
private struct MapHint: View {
    @AppStorage("mapHintDismissed") private var dismissed = false
    @State private var visible = true

    var body: some View {
        if !dismissed && visible {
            HStack(spacing: 14) {
                hint("hand.draw", "Sürükle: kaydır")
                hint("plus.magnifyingglass", "Kaydır: yakınlaştır")
                hint("cursorarrow.click", "Klasöre tıkla: içine gir")
                hint("cursorarrow.click.2", "Çift tıkla: editörde aç")
                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Bir daha gösterme")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .transition(.opacity)
            .task {
                try? await Task.sleep(for: .seconds(14))
                withAnimation { visible = false }
            }
        }
    }

    private func hint(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: symbol).labelStyle(.titleAndIcon)
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
                    .buttonStyle(.accent)
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
