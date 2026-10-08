import MapoCore
import Foundation
import Observation

/// Runs the engine for every project, one at a time, at low priority.
///
/// Workspaces, the sidebar and the menu bar all read `status` from here, so
/// indexing a project that is not open (auto-update after a commit) looks
/// the same everywhere.
@MainActor
@Observable
final class IndexCoordinator {
    enum Status: Equatable {
        case queued
        case running(Engine.Phase)
        case failed(String)
    }

    /// Absent = idle.
    private(set) var status: [UUID: Status] = [:]

    var isBusy: Bool { status.values.contains { if case .failed = $0 { false } else { true } } }

    @ObservationIgnored var projectProvider: (UUID) -> Project? = { _ in nil }
    /// Called on the main actor after a successful run.
    @ObservationIgnored var onFinished: (UUID, Project.IndexRecord) -> Void = { _, _ in }

    private let paths: MapoPaths
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var running: (id: UUID, task: Task<Void, Never>)?
    /// Changes arrived while this project was being indexed: run once more.
    @ObservationIgnored private var rerun: Set<UUID> = []

    /// Automatic updates held back while Low Power Mode is on (PLAN §3.3).
    private(set) var deferred: Set<UUID> = []
    @ObservationIgnored private var powerObserver: NSObjectProtocol?

    init(paths: MapoPaths) {
        self.paths = paths
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.powerChanged() }
        }
    }

    /// An update nobody asked for (file watcher, git, catch-up): waits while
    /// the Mac is saving power. Asking for one (button, ⌘R) never waits.
    func enqueueAutomatic(_ id: UUID) {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            deferred.insert(id)
            return
        }
        enqueue(id)
    }

    private func powerChanged() {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled, !deferred.isEmpty else { return }
        let ids = deferred
        deferred.removeAll()
        ids.sorted { $0.uuidString < $1.uuidString }.forEach(enqueue)
    }

    var engineAvailable: Bool { Engine.locate() != nil }

    func isWorking(on id: UUID) -> Bool {
        switch status[id] {
        case .queued, .running: true
        default: false
        }
    }

    func enqueue(_ id: UUID) {
        deferred.remove(id)
        if running?.id == id {
            rerun.insert(id)
            return
        }
        guard !queue.contains(id) else { return }
        queue.append(id)
        status[id] = .queued
        pump()
    }

    func cancel(_ id: UUID) {
        rerun.remove(id)
        if let i = queue.firstIndex(of: id) {
            queue.remove(at: i)
            status[id] = nil
        }
        if running?.id == id { running?.task.cancel() }
    }

    func clearError(_ id: UUID) {
        if case .failed = status[id] { status[id] = nil }
    }

    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let project = projectProvider(id) else {
            status[id] = nil
            return pump()
        }
        guard let engine = Engine.locate() else {
            status[id] = .failed(Engine.EngineError.notFound.errorDescription ?? "")
            return pump()
        }
        status[id] = .running(.scanning)

        let root = project.rootURL
        let output = paths.engineOutput(id)
        let graphURL = paths.graphFile(id)
        let report: @Sendable (Engine.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in
                guard let self, self.running?.id == id else { return }
                self.status[id] = .running(phase)
            }
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            let result: Result<Project.IndexRecord, Error>
            do {
                let head = await GitInfo.head(at: root)
                try await engine.index(root: root, output: output, logName: id.uuidString, progress: report)
                // HTTP routes / SQL tables graphify can't see (PLAN §3.6), from
                // graphify's own graph so a stale bridges file never feeds back.
                if let raw = try? Data(contentsOf: graphURL), let (plain, _) = try? GraphLoader.decode(raw) {
                    Bridges.write(root: root, graph: plain, graphDir: graphURL.deletingLastPathComponent())
                }
                let (graph, meta) = try GraphLoader.load(from: graphURL)
                result = .success(Project.IndexRecord(
                    finishedAt: .now,
                    commit: head?.commit,
                    branch: head?.branch,
                    engineVersion: meta.engineVersion,
                    nodeCount: graph.nodes.count,
                    edgeCount: graph.edges.count,
                    fileCount: graph.nodes.count { $0.kind == .file }
                ))
            } catch {
                result = .failure(error)
            }
            await self?.finish(id, result)
        }
        running = (id, task)
    }

    private func finish(_ id: UUID, _ result: Result<Project.IndexRecord, Error>) {
        running = nil
        switch result {
        case .success(let record):
            status[id] = nil
            onFinished(id, record)
        case .failure(let error) where error is CancellationError:
            status[id] = nil
        case .failure(let error):
            status[id] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        if rerun.remove(id) != nil { enqueue(id) }
        pump()
    }
}
