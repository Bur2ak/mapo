import AppKit
import MapoCore
import SwiftUI

/// Right-hand panel: what the selected node is, where it lives, and how it
/// connects. Every related node is one click away.
struct InspectorView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            if let graph = workspace.graph, let overlay = workspace.overlay {
                OverlayInspector(graph: graph, overlay: overlay)
            } else if let graph = workspace.graph, let id = workspace.selectedID, let position = graph.position(of: id) {
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
        let children = unique(graph.children(of: position))
        let routes = children.filter { graph.nodes[$0].kind == .route }
        let tables = children.filter { graph.nodes[$0].kind == .table }
        RelationSection(title: "Uç noktaları", positions: routes, graph: graph)
        RelationSection(title: "Tanımladığı tablolar", positions: tables, graph: graph)
        RelationSection(title: "İçindekiler", positions: children.filter { !routes.contains($0) && !tables.contains($0) }, graph: graph)
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
        RelationSection(title: "İstek atanlar", positions: related(.requests, incoming: true), graph: graph)
        RelationSection(title: "Attığı istekler", positions: related(.requests, incoming: false), graph: graph)
        RelationSection(title: "Okuyanlar", positions: related(.reads, incoming: true), graph: graph)
        RelationSection(title: "Yazanlar", positions: related(.writes, incoming: true), graph: graph)
        RelationSection(title: "Okuduğu tablolar", positions: related(.reads, incoming: false), graph: graph)
        RelationSection(title: "Yazdığı tablolar", positions: related(.writes, incoming: false), graph: graph)
        if let parent = graph.parent(of: position), graph.nodes[parent].kind != .file || node.kind != .file {
            RelationSection(title: "Tanımlandığı yer", positions: [parent], graph: graph)
        }
    }

    private var actions: some View {
        HStack {
            Button {
                workspace.showImpact(of: position)
            } label: {
                Label("Etki alanı", systemImage: "dot.radiowaves.left.and.right")
            }
            .help("Bu değişirse nelerin etkilenebileceğini haritada göster")

            Button {
                workspace.beginPath(from: position)
            } label: {
                Label("Yol bul…", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .help("Buradan başka bir dosya ya da fonksiyona giden bağlantı zincirini göster")

            Spacer(minLength: 0)

            Button {
                workspace.map.focus(node.id)
            } label: {
                Image(systemName: "scope")
            }
            .help("Haritada bul")
            .accessibilityLabel("Haritada bul")

            Menu {
                Button("Mermaid Olarak Kopyala") { workspace.copyMermaid() }
                Button("Görüntü Olarak Kaydet…") { Task { await workspace.exportImage() } }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Dışa aktar")
            .accessibilityLabel("Dışa aktar")
        }
        .controlSize(.small)
    }

    /// Bridge edges (HTTP / SQL) of one relation, in one direction.
    private func related(_ r: Relation, incoming: Bool) -> [Int] {
        let list = incoming ? graph.incoming[position] : graph.outgoing[position]
        return unique(list.compactMap { e in
            let edge = graph.edges[e]
            guard edge.relation == r else { return nil }
            return incoming ? edge.sourcePosition : edge.targetPosition
        })
    }

    private func unique(_ positions: [Int]) -> [Int] {
        var seen = Set<Int>()
        return positions.filter { $0 != position && seen.insert($0).inserted }
    }
}

/// The answer to "how does A reach B" or "what breaks if this changes",
/// step by step, while the map shows it.
private struct OverlayInspector: View {
    @Environment(Workspace.self) private var workspace
    let graph: Graph
    let overlay: Workspace.Overlay

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch overlay {
                case .path(let result): path(result)
                case .noPath(let from, let to): noPath(from, to)
                case .impact(let of, let rings): impact(of, rings)
                }
                HStack {
                    Button("Kapat") { workspace.clearOverlay() }
                        .keyboardShortcut(.cancelAction)
                    if case .path = overlay {
                        Button("Mermaid Olarak Kopyala") { workspace.copyMermaid() }
                    }
                }
                .controlSize(.small)
            }
            .padding(16)
        }
    }

    private func header(_ kind: LocalizedStringKey, symbol: String, title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(kind, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func name(_ p: Int) -> String {
        let n = graph.nodes[p]
        return n.kind == .file ? n.label : n.name
    }

    @ViewBuilder private func path(_ r: Graph.PathResult) -> some View {
        let first = r.nodes.first ?? 0, last = r.nodes.last ?? 0
        header("Yol", symbol: "point.topleft.down.to.point.bottomright.curvepath",
               title: "\(name(first)) → \(name(last))",
               subtitle: r.directed
                   ? String(localized: "\(r.edges.count) adımda ulaşıyor.")
                   : String(localized: "Doğrudan ulaşmıyor; aralarındaki en kısa bağ \(r.edges.count) adım (yön gözetmeden)."))
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(r.nodes.enumerated()), id: \.offset) { i, p in
                RelationRow(node: graph.nodes[p])
                if i < r.edges.count {
                    let e = graph.edges[r.edges[i]]
                    let forward = e.sourcePosition == p
                    Label(Self.verb(e.relation, forward: forward), systemImage: "arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)
                        .padding(.vertical, 1)
                }
            }
        }
    }

    @ViewBuilder private func noPath(_ from: Int, _ to: Int) -> some View {
        header("Yol", symbol: "point.topleft.down.to.point.bottomright.curvepath",
               title: "\(name(from)) → \(name(to))",
               subtitle: String(localized: "Bu ikisi arasında bağlantı zinciri yok: biri diğerini hiçbir yoldan kullanmıyor."))
    }

    @ViewBuilder private func impact(_ of: Int, _ rings: [[Int]]) -> some View {
        let affected = rings.dropFirst().reduce(0) { $0 + $1.count }
        header("Etki alanı", symbol: "dot.radiowaves.left.and.right", title: name(of),
               subtitle: affected == 0
                   ? String(localized: "Hiçbir yer buna bağlı değil; değişmesi başka bir şeyi bozmaz.")
                   : String(localized: "Bu değişirse \(affected) yer etkilenebilir."))
        ForEach(Array(rings.enumerated().dropFirst()), id: \.offset) { depth, ring in
            ImpactRing(title: depth == 1 ? "Doğrudan kullananlar" : "\(depth). derece", positions: ring, graph: graph)
        }
    }

    static func verb(_ r: Relation, forward: Bool) -> LocalizedStringKey {
        switch (r, forward) {
        case (.calls, true), (.indirectCall, true): "çağırır"
        case (.calls, false), (.indirectCall, false): "tarafından çağrılır"
        case (.contains, true), (.method, true): "içerir"
        case (.contains, false), (.method, false): "içinde"
        case (.inherits, true): "miras alır"
        case (.inherits, false): "tarafından miras alınır"
        case (.references, true): "kullanır"
        case (.references, false): "tarafından kullanılır"
        case (.requests, true): "istek atar"
        case (.requests, false): "isteğini karşılar"
        case (.reads, true): "okur"
        case (.reads, false): "tarafından okunur"
        case (.writes, true): "yazar"
        case (.writes, false): "tarafından yazılır"
        case (_, true) where r.isImport: "içe aktarır"
        case (_, false) where r.isImport: "tarafından içe aktarılır"
        default: forward ? "bağlı" : "bağlı (ters yön)"
        }
    }
}

private struct ImpactRing: View {
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
                    Button(showAll ? "Daha az göster" : "\(positions.count - limit) tane daha") { showAll.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.leading, 24)
                }
            }
        }
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
                    Spacer(minLength: 8)
                    Text("bağlantı")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Bu iki dosya arasındaki çağrı ve içe aktarma sayısı")
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
    /// Fits the widest line number shown (monospaced 11 pt ≈ 6.7 pt a digit).
    private var gutter: CGFloat { CGFloat(String(lines.last?.0 ?? 0).count) * 6.8 + 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.0) { number, text in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // Verbatim: no "1.188" grouping; wide enough for 5 digits.
                    Text(verbatim: String(number))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: gutter, alignment: .trailing)
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
                    Text(workspace.project.displayName)
                        .font(.title3.weight(.semibold))
                    if let graph = workspace.graph {
                        Text(summary(graph))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if !workspace.map.groups.isEmpty {
                    OverviewSection(title: legendTitle, unit: "dosya") {
                        ForEach(workspace.map.groups) { group in
                            LegendRow(group: group, unit: "dosya")
                        }
                    }
                }

                if let graph = workspace.graph {
                    let hubs = Self.hubs(in: graph, excluding: workspace.noisyFiles)
                    if !hubs.isEmpty {
                        OverviewSection(title: "Merkez dosyalar", help: "Diğer dosyalarla en çok bağı olanlar: değişince en çok yeri etkileyenler.", unit: "bağlantı") {
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

    private var legendTitle: LocalizedStringKey {
        switch workspace.map.groupsMode {
        case .folder: "Bölgeler"
        case .recency: "Son değişiklik"
        case .coupling: "Bağlantı yoğunluğu"
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
    /// What the numbers on the right count.
    var unit: LocalizedStringKey? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help(help.map { Text($0) } ?? Text(""))
                Spacer(minLength: 8)
                if let unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
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
                Text(group.name.isEmpty ? String(localized: "Diğer") : group.name)
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
        case .route: "HTTP uç noktası"
        case .table: "Tablo"
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
        case .route: "network"
        case .table: "tablecells"
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
