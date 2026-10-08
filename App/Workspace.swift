import MapoCore
import AppKit
import Foundation
import Observation

/// Everything about one open project: its graph, search index, map, and
/// indexing state. Heavy work (decode, payload, engine) runs off the main actor.
@MainActor
@Observable
final class Workspace {
    enum State: Equatable {
        case loading
        /// No graph on disk yet.
        case needsIndex
        case indexing(Engine.Phase)
        case ready
        case failed(String)
    }

    /// What the workspace shows: its own load state, overlaid with the
    /// coordinator's indexing state while there is no map yet.
    var state: State {
        if graph == nil {
            switch indexer.status[project.id] {
            case .queued: return .indexing(.scanning)
            case .running(let phase): return .indexing(phase)
            case .failed(let message): return .failed(message)
            case nil: break
            }
        }
        return loadState
    }

    struct Freshness: Equatable {
        var head: GitInfo.Head?
        /// Commits since the indexed commit; nil when unknown / not a repo.
        var behind: Int?
    }

    private(set) var project: Project
    private var loadState: State = .loading
    private(set) var graph: Graph?
    private(set) var search: SearchIndex?
    private(set) var freshness = Freshness()
    /// Minified bundles found on disk (hidden from the map and lists).
    private(set) var noisyFiles: Set<String> = []
    /// A re-index runs over an existing map (the map stays usable).
    var isRefreshing: Bool { graph != nil && indexer.isWorking(on: project.id) }

    /// Error from a background refresh; the old map stays on screen.
    var lastIndexError: String? {
        get {
            guard graph != nil, case .failed(let m) = indexer.status[project.id] else { return nil }
            return m
        }
        set { if newValue == nil { indexer.clearError(project.id) } }
    }

    var selectedID: String?
    var isSearchPresented = false

    /// A question answered on the map, shown in the inspector until dismissed.
    enum Overlay: Equatable {
        case path(Graph.PathResult)
        case noPath(from: Int, to: Int)
        case impact(of: Int, rings: [[Int]])
    }
    private(set) var overlay: Overlay?
    /// Picking the other end of a path in the palette.
    private(set) var pathStart: Int?

    let map: MapController
    private let paths: MapoPaths
    private let indexer: IndexCoordinator
    @ObservationIgnored private var payloadData: Data?

    init(project: Project, paths: MapoPaths, indexer: IndexCoordinator) {
        self.project = project
        self.paths = paths
        self.indexer = indexer
        var provider: ((String) -> Data?)?
        map = MapController { id in provider?(id) }
        provider = { [weak self] id in
            guard let self, id == self.project.id.uuidString else { return nil }
            return self.payloadData
        }
        map.onEvent = { [weak self] in self?.handle($0) }
    }

    var selectedNode: Node? {
        guard let selectedID, let graph else { return nil }
        return graph.node(selectedID)
    }

    // MARK: Lifecycle

    func open() async {
        // A warm workspace (switching back to a project) is already loaded.
        if graph != nil {
            await refreshFreshness()
            return
        }
        let graphURL = paths.graphFile(project.id)
        guard FileManager.default.fileExists(atPath: graphURL.path) else {
            loadState = .needsIndex
            await refreshFreshness()
            return
        }
        await loadGraph()
        await refreshFreshness()
    }

    /// The engine finished for this project (possibly in the background):
    /// pick up the new graph without moving the user's view.
    func indexFinished(_ updated: Project) async {
        project = updated
        await loadGraph(keepView: graph != nil)
        await refreshFreshness()
    }

    private func loadGraph(keepView: Bool = false) async {
        let graphURL = paths.graphFile(project.id)
        let layoutURL = layoutFile
        let rootPath = project.rootPath
        do {
            let ages = await GitInfo.fileAges(at: URL(fileURLWithPath: rootPath, isDirectory: true))
            let (graph, search, data, minifiedFiles) = try await Task.detached(priority: .userInitiated) {
                let (graph, _) = try GraphLoader.load(from: graphURL)
                let positions = (try? Data(contentsOf: layoutURL)).flatMap {
                    try? JSONDecoder().decode([String: [Double]].self, from: $0)
                }
                let root = URL(fileURLWithPath: rootPath, isDirectory: true)
                let minified = Set(graph.nodes.lazy.filter { $0.kind == .file }.compactMap(\.sourceFile).filter {
                    NoiseFilter.looksMinified(root.appendingPathComponent($0))
                })
                // Circle sizes are lines of code: read once, off the main actor.
                var lines: [String: Int] = [:]
                for path in Set(graph.nodes.lazy.filter { $0.kind == .file }.compactMap(\.sourceFile)) {
                    lines[path] = Self.lineCount(root.appendingPathComponent(path))
                }
                let data = try MapPayload(graph: graph, positions: positions, noisyFiles: minified,
                                          lineCounts: lines, ages: ages).encoded()
                return (graph, SearchIndex(graph: graph), data, minified)
            }.value
            self.graph = graph
            overlay = nil
            pathStart = nil
            self.search = search
            self.payloadData = data
            self.noisyFiles = minifiedFiles
            if let id = selectedID, graph.node(id) == nil { selectedID = nil }
            loadState = .ready
            map.load(projectID: project.id, keepView: keepView, select: selectedID)
            #if DEBUG
            applyScreenshotArguments()
            #endif
        } catch {
            loadState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Newline count (files over 8 MB count as large, not read).
    nonisolated static func lineCount(_ url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return 0 }
        guard size < 8_000_000, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return size / 40 }
        var n = 0
        data.withUnsafeBytes { raw in for b in raw where b == 0x0A { n += 1 } }
        return data.last == 0x0A || data.isEmpty ? n : n + 1
    }

    func refreshFreshness() async {
        let head = await GitInfo.head(at: project.rootURL)
        var behind: Int?
        if let head, let indexed = project.lastIndex?.commit {
            behind = indexed == head.commit ? 0 : await GitInfo.commitsSince(indexed, at: project.rootURL)
        }
        freshness = Freshness(head: head, behind: behind)
    }

    // MARK: Indexing

    var canIndex: Bool { indexer.engineAvailable }

    func index() { indexer.enqueue(project.id) }

    func cancelIndex() { indexer.cancel(project.id) }

    func close() {}

    // MARK: Selection

    func select(_ id: String?, fly: Bool = true) {
        selectedID = id
        if fly { map.select(id) }
    }

    // MARK: Questions on the map

    func beginPath(from position: Int) {
        pathStart = position
        isSearchPresented = true
    }

    func cancelPath() { pathStart = nil }

    func showPath(to target: Int) {
        guard let graph, let start = pathStart else { return }
        pathStart = nil
        guard let result = graph.shortestPath(from: start, to: target) else {
            overlay = .noPath(from: start, to: target)
            map.clearHighlight()
            return
        }
        overlay = .path(result)
        let steps = result.edges.count
        map.showPath(result.nodes.map { graph.nodes[$0].id }, label: String(localized: "Yol · \(steps) adım"))
    }

    func showImpact(of position: Int) {
        guard let graph else { return }
        let rings = graph.impact(of: position)
        overlay = .impact(of: position, rings: rings)
        let affected = rings.dropFirst().reduce(0) { $0 + $1.count }
        let ids = rings.flatMap { $0 }.prefix(400).map { graph.nodes[$0].id }
        map.highlight(Array(ids), label: String(localized: "Etki alanı · \(affected)"))
    }

    // MARK: Export

    /// Short confirmation shown over the map ("Copied…").
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Mermaid of what's on screen: the path being shown, else the selection.
    var mermaid: String? {
        guard let graph else { return nil }
        if case .path(let r) = overlay { return MermaidExport.path(r, in: graph) }
        guard let id = selectedID, let p = graph.position(of: id) else { return nil }
        return MermaidExport.neighborhood(of: p, in: graph)
    }

    func copyMermaid() {
        guard let text = mermaid else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(String(localized: "Mermaid diyagramı panoya kopyalandı"))
    }

    func exportImage() async {
        guard let png = await map.snapshotPNG() else {
            showToast(String(localized: "Görüntü alınamadı"))
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(project.name) haritası.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url, options: .atomic)
            showToast(String(localized: "Görüntü kaydedildi"))
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func clearOverlay() {
        overlay = nil
        map.clearHighlight()
    }

    func node(at position: Int) -> Node? {
        graph.map { $0.nodes[position] }
    }

    func fileURL(for node: Node) -> URL? {
        guard let file = node.sourceFile else { return nil }
        let url = project.rootURL.appendingPathComponent(file)
        // Never resolve outside the project (e.g. `../` in a crafted graph).
        let root = project.rootURL.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return url
    }

    #if DEBUG
    /// Visual QA harness: `-mapoDetail 1 -mapoZoom 2.5 -mapoGroup 0 -mapoHideTests YES -mapoSelect <id> -mapoSearch <q>`
    /// puts the map in a given state on launch, so screenshots never depend
    /// on synthesized clicks reaching the window.
    private func applyScreenshotArguments() {
        let d = UserDefaults.standard
        if d.object(forKey: "mapoDetail") != nil, let level = MapController.Detail(rawValue: d.integer(forKey: "mapoDetail")) {
            map.detail = level
        }
        if let c = d.string(forKey: "mapoColor"), let mode = MapController.ColorMode(rawValue: c) { map.colorMode = mode }
        if d.bool(forKey: "mapoHideTests") { map.hideTests = true }
        if let l = d.string(forKey: "mapoLinks"), let f = MapController.LinkFilter(rawValue: l) { map.linkFilter = f }
        let zoom = d.double(forKey: "mapoZoom")
        let select = d.string(forKey: "mapoSelect")
        let search = d.string(forKey: "mapoSearch")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if zoom > 0 { map.zoom(zoom) }
            if d.object(forKey: "mapoGroup") != nil { map.focusGroup(d.integer(forKey: "mapoGroup")) }
            if let select, let id = graph?.node(select)?.id ?? search.flatMap({ _ in nil }) { self.select(id) }
            if let search, let hit = self.search?.search(search).first, let n = node(at: hit.position) { self.select(n.id) }
            if d.bool(forKey: "mapoPalette") { isSearchPresented = true }
            if let to = d.string(forKey: "mapoPathTo"), let id = selectedID, let from = graph?.position(of: id),
               let hit = self.search?.search(to).first {
                try? await Task.sleep(for: .seconds(1))
                beginPath(from: from)
                isSearchPresented = d.bool(forKey: "mapoPalette")
                if !isSearchPresented { showPath(to: hit.position) }
            }
            if let out = d.string(forKey: "mapoExportTo") {
                try? await Task.sleep(for: .seconds(1.5))
                if let png = await map.snapshotPNG() { try? png.write(to: URL(fileURLWithPath: out)) }
            }
            if d.bool(forKey: "mapoCopyMermaid") {
                try? await Task.sleep(for: .seconds(1))
                copyMermaid()
            }
            if d.bool(forKey: "mapoImpact"), let id = selectedID, let p = graph?.position(of: id) {
                try? await Task.sleep(for: .seconds(1))
                showImpact(of: p)
            }
        }
    }
    #endif

    // MARK: Map events

    private var layoutFile: URL {
        paths.projectDir(project.id).appendingPathComponent("layout.json")
    }

    private func handle(_ event: MapController.Event) {
        switch event {
        case .select(let id):
            selectedID = id
        case .highlightCleared:
            overlay = nil
        case .open(let id):
            if let node = graph?.node(id) { Editor.open(node: node, in: self) }
        case .layout(let positions):
            let url = layoutFile
            Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(positions) else { return }
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        case .error(let message):
            NSLog("Mapo map error: \(message)")
        case .loaded, .layoutProgress:
            break
        }
    }
}
