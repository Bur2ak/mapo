import MapoCore
import SwiftUI

/// ⌘K palette floating over the map. ↑↓ to move, ↩ to fly there,
/// ⌘↩ to open in the editor, esc to close.
struct SearchPalette: View {
    @Environment(Workspace.self) private var workspace
    @State private var query = ""
    @State private var hits: [SearchIndex.Hit] = []
    @State private var cursor = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Sembol, dosya ya da yol ara", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { choose(open: false) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        choose(open: true)
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if !hits.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        // Identity = node position (one identity only; an
                        // extra index-based .id made SwiftUI keep stale rows).
                        VStack(spacing: 2) {
                            ForEach(Array(hits.enumerated()), id: \.element.position) { i, hit in
                                if let node = workspace.node(at: hit.position) {
                                    SearchRow(node: node, ranges: hit.ranges, isActive: i == cursor)
                                        .onTapGesture { cursor = i; choose(open: false) }
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(CGFloat(hits.count) * 46 + 12, 380))
                    .onChange(of: cursor) { _, c in
                        if hits.indices.contains(c) { proxy.scrollTo(hits[c].position) }
                    }
                }
                Divider()
                HStack(spacing: 14) {
                    hint("↩", "Haritada göster")
                    hint("⌘↩", "Editörde aç")
                    hint("esc", "Kapat")
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider()
                Text("Sonuç yok")
                    .foregroundStyle(.secondary)
                    .padding(18)
            }
        }
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .onAppear {
            focused = true
            #if DEBUG
            if let q = UserDefaults.standard.string(forKey: "mapoPaletteQuery") { query = q }
            #endif
        }
        .onChange(of: query) { _, q in
            hits = workspace.search?.search(q, limit: 60) ?? []
            cursor = 0
        }
    }

    private func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        cursor = (cursor + delta + hits.count) % hits.count
    }

    private func choose(open: Bool) {
        guard hits.indices.contains(cursor), let node = workspace.node(at: hits[cursor].position) else { return }
        workspace.select(node.id)
        if open { Editor.open(node: node, in: workspace) }
        close()
    }

    private func close() {
        workspace.isSearchPresented = false
    }

    private func hint(_ key: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(text).font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

private struct SearchRow: View {
    let node: Node
    let ranges: [Int]
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.kind.symbol)
                .frame(width: 18)
                .foregroundStyle(isActive ? Palette.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                highlighted
                    .lineLimit(1)
                if let file = node.sourceFile {
                    Text(node.kind == .file ? (file as NSString).deletingLastPathComponent : file)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            Text(node.kind.title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Palette.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// Name with matched characters in bold.
    private var highlighted: Text {
        let name = node.kind == .file ? node.label : node.name
        let marked = Set(ranges)
        var out = Text("")
        for (i, ch) in name.enumerated() {
            let t = Text(String(ch))
            out = out + (marked.contains(i) ? t.bold().foregroundColor(Palette.label) : t)
        }
        return out
    }
}
