import AtlasCore
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

    struct Freshness: Equatable {
        var head: GitInfo.Head?
        /// Commits since the indexed commit; nil when unknown / not a repo.
        var behind: Int?
    }

    private(set) var project: Project
    private(set) var state: State = .loading
    private(set) var graph: Graph?
    private(set) var search: SearchIndex?
    private(set) var freshness = Freshness()
    /// Minified bundles found on disk (hidden from the map and lists).
    private(set) var noisyFiles: Set<String> = []
    /// Set while a re-index runs over an existing map (map stays usable).
    private(set) var isRefreshing = false

    var selectedID: String?
    var isSearchPresented = false

    let map: MapController
    private let paths: AtlasPaths
    private let onProjectChange: (Project) -> Void
    @ObservationIgnored private var payloadData: Data?
    @ObservationIgnored private var indexTask: Task<Void, Never>?

    init(project: Project, paths: AtlasPaths, onProjectChange: @escaping (Project) -> Void) {
        self.project = project
        self.paths = paths
        self.onProjectChange = onProjectChange
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
        let graphURL = paths.graphFile(project.id)
        guard FileManager.default.fileExists(atPath: graphURL.path) else {
            state = .needsIndex
            await refreshFreshness()
            return
        }
        await loadGraph()
        await refreshFreshness()
    }

    private func loadGraph() async {
        let graphURL = paths.graphFile(project.id)
        let layoutURL = layoutFile
        let rootPath = project.rootPath
        do {
            let (graph, search, data, minifiedFiles) = try await Task.detached(priority: .userInitiated) {
                let (graph, _) = try GraphLoader.load(from: graphURL)
                let positions = (try? Data(contentsOf: layoutURL)).flatMap {
                    try? JSONDecoder().decode([String: [Double]].self, from: $0)
                }
                let root = URL(fileURLWithPath: rootPath, isDirectory: true)
                let minified = Set(graph.nodes.lazy.filter { $0.kind == .file }.compactMap(\.sourceFile).filter {
                    NoiseFilter.looksMinified(root.appendingPathComponent($0))
                })
                let data = try MapPayload(graph: graph, positions: positions, noisyFiles: minified).encoded()
                return (graph, SearchIndex(graph: graph), data, minified)
            }.value
            self.graph = graph
            self.search = search
            self.payloadData = data
            self.noisyFiles = minifiedFiles
            if let id = selectedID, graph.node(id) == nil { selectedID = nil }
            state = .ready
            map.load(projectID: project.id)
            #if DEBUG
            applyScreenshotArguments()
            #endif
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
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

    var canIndex: Bool { Engine.locate() != nil }

    func index() {
        guard indexTask == nil else { return }
        guard let engine = Engine.locate() else {
            state = graph == nil ? .failed(Engine.EngineError.notFound.errorDescription ?? "") : state
            return
        }
        let hadGraph = graph != nil
        isRefreshing = hadGraph
        if !hadGraph { state = .indexing(.scanning) }

        let root = project.rootURL
        let output = paths.engineOutput(project.id)
        let logName = project.id.uuidString
        let report: @Sendable (Engine.Phase) -> Void = { [weak self] phase in
            guard let workspace = self else { return }
            Task { @MainActor in workspace.apply(phase) }
        }
        indexTask = Task { [weak self] in
            do {
                let head = await GitInfo.head(at: root)
                try await engine.index(root: root, output: output, logName: logName, progress: report)
                guard let self else { return }
                await self.loadGraph()
                if let graph = self.graph {
                    self.project.lastIndex = Project.IndexRecord(
                        finishedAt: .now,
                        commit: head?.commit,
                        branch: head?.branch,
                        engineVersion: nil,
                        nodeCount: graph.nodes.count,
                        edgeCount: graph.edges.count,
                        fileCount: graph.nodes.count { $0.kind == .file }
                    )
                    self.onProjectChange(self.project)
                }
                await self.refreshFreshness()
            } catch is CancellationError {
                if let self, !hadGraph { self.state = .needsIndex }
            } catch {
                guard let self else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if hadGraph {
                    self.lastIndexError = message
                } else {
                    self.state = .failed(message)
                }
            }
            self?.isRefreshing = false
            self?.indexTask = nil
        }
    }

    private func apply(_ phase: Engine.Phase) {
        // A refresh over an existing map reports in the toolbar, not full screen.
        guard !isRefreshing, indexTask != nil else { return }
        state = .indexing(phase)
    }

    /// Error from a background refresh; the old map stays on screen.
    var lastIndexError: String?

    func cancelIndex() {
        indexTask?.cancel()
    }

    func close() {
        indexTask?.cancel()
    }

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
        guard url.standardizedFileURL.path.hasPrefix(project.rootURL.standardizedFileURL.path) else { return nil }
        return url
    }

    #if DEBUG
    /// Visual QA harness: `-atlasDetail 1 -atlasZoom 2.5 -atlasSelect <id> -atlasSearch <q>`
    /// puts the map in a given state on launch, so screenshots never depend
    /// on synthesized clicks reaching the window.
    private func applyScreenshotArguments() {
        let d = UserDefaults.standard
        if d.object(forKey: "atlasDetail") != nil, let level = MapController.Detail(rawValue: d.integer(forKey: "atlasDetail")) {
            map.detail = level
        }
        let zoom = d.double(forKey: "atlasZoom")
        let select = d.string(forKey: "atlasSelect")
        let search = d.string(forKey: "atlasSearch")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if zoom > 0 { map.zoom(zoom) }
            if let select, let id = graph?.node(select)?.id ?? search.flatMap({ _ in nil }) { self.select(id) }
            if let search, let hit = self.search?.search(search).first, let n = node(at: hit.position) { self.select(n.id) }
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
            NSLog("Atlas map error: \(message)")
        case .loaded, .layoutProgress:
            break
        }
    }
}
