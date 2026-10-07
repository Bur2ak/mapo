import AppKit
import MapoCore
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
                ProjectOverview()
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
        if node.kind == .file {
            fileRelations
        } else {
            symbolRelations
        }
    }

    /// A file talks in files: what it uses, who uses it, what it declares.
    @ViewBuilder
    private var fileRelations: some View {
        let deps = graph.fileDependencies(of: position)
        // Config / build output is not a dependency anyone wants to read about.
        let meaningful = { (d: Graph.FileDependency) -> Bool in
            guard let f = graph.nodes[d.file].sourceFile else { return true }
            return !workspace.noisyFiles.contains(f) && !NoiseFilter.isNoise(path: f)
        }
        FileDependencySection(title: "Kullandığı dosyalar", deps: deps.uses.filter(meaningful), graph: graph)
        FileDependencySection(title: "Kullanan dosyalar", deps: deps.usedBy.filter(meaningful), graph: graph)
        RelationSection(title: "İçindekiler", positions: unique(graph.children(of: position)), graph: graph)
    }

    @ViewBuilder
    private var symbolRelations: some View {
        let callers = unique(graph.callers(of: position).map(\.node))
        let callees = unique(graph.callees(of: position).map(\.node))
        let importers = unique(graph.importers(of: position).map(\.node))
        let imports = unique(graph.imports(of: position).map(\.node))
        let children = unique(graph.children(of: position))

        RelationSection(title: "Çağıranlar", positions: callers, graph: graph)
        RelationSection(title: "Çağırdıkları", positions: callees, graph: graph)
        RelationSection(title: "İçe aktaranlar", positions: importers, graph: graph)
        RelationSection(title: "İçe aktardıkları", positions: imports, graph: graph)
        RelationSection(title: "Üyeler", positions: children, graph: graph)
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

private struct FileDependencySection: View {
    let title: LocalizedStringKey
    let deps: [Graph.FileDependency]
    let graph: Graph
    @State private var showAll = false
    private let limit = 10

    var body: some View {
        if !deps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(deps.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                ForEach(showAll ? deps : Array(deps.prefix(limit)), id: \.file) { d in
                    RelationRow(node: graph.nodes[d.file], trailing: "\(d.weight)")
                        .help("\(d.weight) bağlantı")
                }
                if deps.count > limit {
                    Button(showAll ? "Daha az göster" : "\(deps.count - limit) tane daha") { showAll.toggle() }
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
    var trailing: String? = nil
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
                    if let file = node.sourceFile {
                        Text(node.kind == .file ? (file as NSString).deletingLastPathComponent.shortPath : file.shortPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
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

/// Shown when nothing is selected: what this codebase is made of, where the
/// weight sits, and what moved recently. Doubles as the map legend.
private struct ProjectOverview: View {
    @Environment(Workspace.self) private var workspace
    @State private var changed: [Int] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.project.name)
                        .font(.title3.weight(.semibold))
                    if let graph = workspace.graph {
                        Text(summary(graph))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if !workspace.map.groups.isEmpty {
                    OverviewSection(title: workspace.map.groupsMode == .folder ? "Bölgeler" : "Modüller") {
                        ForEach(workspace.map.groups) { group in
                            LegendRow(group: group, unit: workspace.map.groupsMode == .folder ? "dosya" : "öğe")
                        }
                    }
                }

                if let graph = workspace.graph {
                    let hubs = Self.hubs(in: graph, excluding: workspace.noisyFiles)
                    if !hubs.isEmpty {
                        OverviewSection(title: "Merkez dosyalar", help: "Diğer dosyalarla en çok bağı olanlar: değişince en çok yeri etkileyenler.") {
                            ForEach(hubs, id: \.0) { p, score in
                                FileRow(node: graph.nodes[p], trailing: "\(score)")
                            }
                        }
                    }
                    if !changed.isEmpty {
                        OverviewSection(title: "Son değişenler", help: "Son 5 commit ve kaydedilmemiş değişiklikler.") {
                            ForEach(changed.prefix(8), id: \.self) { p in
                                FileRow(node: graph.nodes[p], trailing: nil)
                            }
                        }
                    }
                }

                if workspace.graph != nil {
                    Text("Haritada bir dosyaya tıkla ya da ⌘K ile ara.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
        }
        .task(id: workspace.project.lastIndex?.finishedAt) {
            guard let graph = workspace.graph else { return }
            let files = await GitInfo.recentlyChangedFiles(at: workspace.project.rootURL, commits: 5)
            changed = graph.nodes.indices.filter {
                graph.nodes[$0].kind == .file && (graph.nodes[$0].sourceFile.map(files.contains) ?? false)
            }
        }
    }

    private func summary(_ graph: Graph) -> String {
        let files = graph.nodes.count { $0.kind == .file }
        let functions = graph.nodes.count { $0.kind == .function || $0.kind == .method }
        return String(localized: "\(files) dosya · \(functions) fonksiyon · \(graph.edges.count) bağlantı")
    }

    /// File-to-file connections (in + out), lifted from symbol edges.
    static func fileScores(_ graph: Graph) -> [Int: Int] {
        let links = MapPayload.fileLinks(graph)
        var score: [Int: Int] = [:]
        for i in links.s.indices {
            score[links.s[i], default: 0] += links.w[i]
            score[links.t[i], default: 0] += links.w[i]
        }
        return score
    }

    /// The files the rest of the code leans on most (no tests, config,
    /// build output or bundles). External packages never count.
    static func hubs(in graph: Graph, excluding noisy: Set<String>, limit: Int = 5) -> [(Int, Int)] {
        fileScores(graph)
            .filter { p, _ in
                guard let f = graph.nodes[p].sourceFile else { return false }
                return !noisy.contains(f) && !NoiseFilter.isNoise(path: f) && !MapPayload.isTestPath(f)
            }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }
}

private struct OverviewSection<Content: View>: View {
    let title: LocalizedStringKey
    var help: LocalizedStringKey? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .help(help.map { Text($0) } ?? Text(""))
                .padding(.bottom, 2)
            content
        }
    }
}

private struct LegendRow: View {
    @Environment(Workspace.self) private var workspace
    let group: MapController.Group
    let unit: LocalizedStringKey
    @State private var hovering = false

    var body: some View {
        Button {
            if group.id >= 0 { workspace.map.focusGroup(group.id) }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(group.color)
                    .frame(width: 10, height: 10)
                Text(group.id < 0 ? String(localized: "Diğer") : group.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(group.id < 0 ? .secondary : .primary)
                Spacer(minLength: 8)
                Text("\(group.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(hovering && group.id >= 0 ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(group.id < 0)
        .onHover { hovering = $0 }
        .help(group.id >= 0 ? Text("Haritada bu bölgeye git") : Text(""))
    }
}

private struct FileRow: View {
    @Environment(Workspace.self) private var workspace
    let node: Node
    let trailing: String?
    @State private var hovering = false

    var body: some View {
        Button {
            workspace.select(node.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text((node.sourceFile.map { ($0 as NSString).lastPathComponent }) ?? node.label)
                        .lineLimit(1)
                    if let file = node.sourceFile {
                        Text((file as NSString).deletingLastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Bağlantı sayısı")
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
