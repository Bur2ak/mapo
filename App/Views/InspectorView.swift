import AppKit
import AtlasCore
import SwiftUI

/// Right-hand panel: what the selected node is, where it lives, and how it
/// connects. Every related node is one click away.
struct InspectorView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            if let graph = workspace.graph, let id = workspace.selectedID, let position = graph.position(of: id) {
                NodeInspector(graph: graph, position: position)
                    .id(id)
            } else {
                ProjectSummary()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct NodeInspector: View {
    @Environment(Workspace.self) private var workspace
    let graph: Graph
    let position: Int

    private var node: Node { graph.nodes[position] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if node.sourceFile != nil { location }
                if let url = workspace.fileURL(for: node), node.kind != .file || node.line != nil {
                    CodePreview(url: url, line: node.kind == .file ? 1 : (node.line ?? 1))
                }
                relations
                actions
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(node.kind.title)
            } icon: {
                Image(systemName: node.kind.symbol)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)

            Text(node.kind == .file ? node.label : node.name)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    private var location: some View {
        HStack(spacing: 8) {
            Button {
                Editor.open(node: node, in: workspace)
            } label: {
                Text(locationText)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.link)
            .help("\(Editor.preferred.title) ile aç (⌘↩)")

            Button {
                if let url = workspace.fileURL(for: node) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Finder'da göster")
        }
    }

    private var locationText: String {
        guard let file = node.sourceFile else { return "" }
        if node.kind == .file { return file }
        return node.line.map { "\(file):\($0)" } ?? file
    }

    @ViewBuilder
    private var relations: some View {
        let callers = unique(graph.callers(of: position).map(\.node))
        let callees = unique(graph.callees(of: position).map(\.node))
        let importers = unique(graph.importers(of: position).map(\.node))
        let imports = unique(graph.imports(of: position).map(\.node))
        let children = unique(graph.children(of: position))

        RelationSection(title: "Çağıranlar", positions: callers, graph: graph)
        RelationSection(title: "Çağırdıkları", positions: callees, graph: graph)
        RelationSection(title: "İçe aktaranlar", positions: importers, graph: graph)
        RelationSection(title: "İçe aktardıkları", positions: imports, graph: graph)
        RelationSection(title: node.kind == .file ? "İçindekiler" : "Üyeler", positions: children, graph: graph)
        if let parent = graph.parent(of: position), graph.nodes[parent].kind != .file || node.kind != .file {
            RelationSection(title: "Tanımlandığı yer", positions: [parent], graph: graph)
        }
    }

    private var actions: some View {
        HStack {
            Button {
                let rings = graph.impact(of: position)
                let ids = rings.flatMap { $0 }.prefix(400).map { graph.nodes[$0].id }
                workspace.map.highlight(Array(ids))
            } label: {
                Label("Etki alanı", systemImage: "dot.radiowaves.left.and.right")
            }
            .help("Bu değişirse nelerin etkilenebileceğini haritada göster")

            Button {
                workspace.map.focus(node.id)
            } label: {
                Label("Haritada bul", systemImage: "scope")
            }
        }
        .controlSize(.small)
    }

    private func unique(_ positions: [Int]) -> [Int] {
        var seen = Set<Int>()
        return positions.filter { $0 != position && seen.insert($0).inserted }
    }
}

private struct RelationSection: View {
    @Environment(Workspace.self) private var workspace
    let title: LocalizedStringKey
    let positions: [Int]
    let graph: Graph
    @State private var showAll = false

    private let limit = 12

    var body: some View {
        if !positions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(positions.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                ForEach(showAll ? positions : Array(positions.prefix(limit)), id: \.self) { p in
                    RelationRow(node: graph.nodes[p])
                }
                if positions.count > limit {
                    Button(showAll ? "Daha az göster" : "\(positions.count - limit) tane daha") {
                        showAll.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.leading, 24)
                }
            }
        }
    }
}

private struct RelationRow: View {
    @Environment(Workspace.self) private var workspace
    let node: Node
    @State private var hovering = false

    var body: some View {
        Button {
            workspace.select(node.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: node.kind.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(node.kind == .file ? node.label : node.name)
                        .lineLimit(1)
                    if let file = node.sourceFile, node.kind != .file {
                        Text(file.shortPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Editörde Aç") { Editor.open(node: node, in: workspace) }
        }
    }
}

/// Source lines around the node, current line marked.
private struct CodePreview: View {
    let url: URL
    let line: Int
    @State private var lines: [(Int, String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.0) { number, text in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(number)")
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .trailing)
                    Text(text.isEmpty ? " " : text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1)
                .background(number == line ? Palette.accent.opacity(0.16) : .clear)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        .opacity(lines.isEmpty ? 0 : 1)
        .task(id: "\(url.path):\(line)") {
            lines = await Self.read(url: url, around: line)
        }
    }

    static func read(url: URL, around line: Int, before: Int = 3, after: Int = 12) async -> [(Int, String)] {
        await Task.detached(priority: .userInitiated) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attrs[.size] as? Int ?? 0) < 4_000_000,
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { return [] }
            let all = text.split(separator: "\n", omittingEmptySubsequences: false)
            let start = max(1, line - before), end = min(all.count, line + after)
            guard start <= end else { return [] }
            return (start...end).map { ($0, String(all[$0 - 1]).replacingOccurrences(of: "\t", with: "    ")) }
        }.value
    }
}

private struct ProjectSummary: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(workspace.project.name)
                .font(.title3.weight(.semibold))
            if let graph = workspace.graph {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("Dosya", graph.nodes.count { $0.kind == .file })
                    row("Fonksiyon", graph.nodes.count { $0.kind == .function || $0.kind == .method })
                    row("Tip", graph.nodes.count { $0.kind == .type })
                    row("Bağlantı", graph.edges.count)
                }
                .font(.callout)
            }
            Text("Haritada bir noktaya tıkla ya da ⌘K ile ara.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func row(_ title: LocalizedStringKey, _ value: Int) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value.formatted()).monospacedDigit()
        }
    }
}

extension Node.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .file: "Dosya"
        case .function: "Fonksiyon"
        case .method: "Metot"
        case .type: "Tip"
        case .symbol: "Sembol"
        case .external: "Dış bağımlılık"
        case .document: "Belge"
        }
    }

    var symbol: String {
        switch self {
        case .file: "doc.text"
        case .function: "function"
        case .method: "m.square"
        case .type: "cube"
        case .symbol: "number"
        case .external: "shippingbox"
        case .document: "text.book.closed"
        }
    }
}

extension String {
    /// Last two path components: "kulupler/[id].tsx" says more than "[id].tsx".
    var shortPath: String {
        let parts = split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}
