import MapoCore
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
