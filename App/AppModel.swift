import MapoCore
import Foundation
import Observation

/// Window-independent app state: the project library and what is selected.
@MainActor
@Observable
final class AppModel {
    private(set) var projects: [Project] = []
    var selection: Project.ID? {
        didSet { UserDefaults.standard.set(selection?.uuidString, forKey: "lastProject") }
    }
    /// Commits each project's map is behind (nil = unknown / not indexed).
    private(set) var behind: [Project.ID: Int] = [:]
    /// Last user-facing error, shown as an alert.
    var alert: AlertMessage?

    let paths: MapoPaths
    let indexer: IndexCoordinator
    let github = GitHubAccount()
    /// Repositories being cloned (by GitHub id) → last progress line.
    private(set) var cloning: [Int: String] = [:]
    /// Why the last background pull left a project alone (dirty tree…).
    private(set) var syncNotes: [Project.ID: String] = [:]
    @ObservationIgnored private var syncTimer: Task<Void, Never>?
    private let library: ProjectLibrary
    /// One file-system watcher per project while auto-update is on.
    @ObservationIgnored private var watchers: [Project.ID: ProjectWatcher] = [:]

    /// Re-index projects by themselves when their code changes.
    var autoUpdate: Bool = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate")
            syncWatchers()
        }
    }
    /// Open workspaces, most recently used last. A few stay warm so switching
    /// projects is instant; older ones are closed.
    @ObservationIgnored private var workspaces: [Project.ID: Workspace] = [:]
    @ObservationIgnored private var recent: [Project.ID] = []
    private let warmWorkspaces = 3

    init(paths: MapoPaths = .standard) {
        self.paths = paths
        self.library = ProjectLibrary(paths: paths)
        self.indexer = IndexCoordinator(paths: paths)
        indexer.projectProvider = { [weak self] id in self?.projects.first { $0.id == id } }
        indexer.onFinished = { [weak self] id, record in
            Task { await self?.indexFinished(id, record) }
        }
    }

    var selectedProject: Project? {
        projects.first { $0.id == selection }
    }

    func start() async {
        do {
            try await library.load()
            projects = await library.projects
            if selection == nil {
                // Reopen where the user left off.
                let last = UserDefaults.standard.string(forKey: "lastProject").flatMap(UUID.init(uuidString:))
                selection = projects.first { $0.id == last }?.id ?? projects.first?.id
            }
            syncWatchers()
            if projects.isEmpty && !UserDefaults.standard.bool(forKey: "onboardingDone") { showOnboarding = true }
            await refreshStatuses()
            Task { await github.restore() }
            startBackgroundSync()
            // Catch up on what changed while Mapo was closed.
            if autoUpdate {
                for p in projects where p.lastIndex != nil && (behind[p.id] ?? 0) > 0 { indexer.enqueueAutomatic(p.id) }
            }
        } catch {
            alert = AlertMessage(error: error)
        }
    }

    // MARK: Liveness

    /// Starts / stops watchers to match the library and the setting.
    private func syncWatchers() {
        let wanted = autoUpdate ? Set(projects.map(\.id)) : []
        for (id, w) in watchers where !wanted.contains(id) {
            w.stop()
            watchers[id] = nil
        }
        for p in projects where wanted.contains(p.id) && watchers[p.id] == nil {
            let id = p.id
            let w = ProjectWatcher(root: p.rootURL) { [weak self] change in
                Task { @MainActor in self?.projectChanged(id, change) }
            }
            w.start()
            watchers[id] = w
        }
    }

    private func projectChanged(_ id: Project.ID, _ change: ProjectChange) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        if change.git {
            Task {
                await refreshStatus(project)
                await workspaces[id]?.refreshFreshness()
            }
        }
        // Only projects that already have a map update by themselves; the
        // first map is always an explicit choice (it can take a while).
        guard autoUpdate, let indexed = project.lastIndex else { return }
        if change.files.isEmpty {
            // Git-only noise (fetch rewriting FETCH_HEAD, an editor's
            // auto-fetch): re-index only when HEAD actually moved.
            Task {
                guard let head = await GitInfo.head(at: project.rootURL), head.commit != indexed.commit else { return }
                indexer.enqueueAutomatic(id)
            }
            return
        }
        indexer.enqueueAutomatic(id)
    }

    private func indexFinished(_ id: Project.ID, _ record: Project.IndexRecord) async {
        guard var project = projects.first(where: { $0.id == id }) else { return }
        project.lastIndex = record
        await save(project)
        await workspaces[id]?.indexFinished(project)
    }

    // MARK: GitHub

    /// Clones a repository, adds it, and draws its first map (the user asked
    /// for it explicitly, so no extra confirmation).
    func addFromGitHub(_ repo: GitHub.Repository) async {
        if let existing = projects.first(where: {
            if case .github(let o, let r) = $0.source { return o == repo.owner && r == repo.name }
            return false
        }) {
            selection = existing.id
            return
        }
        let destination = RepoSync.defaultDestination(for: repo, paths: paths)
        cloning[repo.id] = String(localized: "Başlıyor…")
        defer { cloning[repo.id] = nil }
        do {
            if !FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path) {
                let token = try await github.accessToken()
                try await RepoSync.clone(repo.cloneURL, to: destination, token: token) { line in
                    Task { @MainActor [weak self] in self?.cloning[repo.id] = Self.cloneProgress(line) }
                }
            }
            let project = try await library.add(folder: destination, name: repo.name, source: .github(owner: repo.owner, repo: repo.name))
            projects = await library.projects
            syncWatchers()
            selection = project.id
            indexer.enqueue(project.id)
        } catch {
            alert = AlertMessage(error: error)
        }
    }

    /// "Receiving objects:  42% (420/1000)" → "%42".
    static func cloneProgress(_ line: String) -> String {
        if let r = line.range(of: #"\d+%"#, options: .regularExpression) {
            let pct = String(line[r]).dropLast()
            return line.hasPrefix("Receiving") ? String(localized: "İndiriliyor %\(String(pct))") : String(localized: "Hazırlanıyor %\(String(pct))")
        }
        return String(localized: "İndiriliyor…")
    }

    /// Every 10 minutes: fast-forward GitHub projects (the file watcher then
    /// re-indexes what changed). Local edits are never touched.
    private func startBackgroundSync() {
        syncTimer?.cancel()
        syncTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                await self?.syncGitHubProjects()
            }
        }
    }

    func syncGitHubProjects() async {
        guard autoUpdate else { return }
        let token = try? await github.accessToken()
        for p in projects {
            guard case .github = p.source else { continue }
            switch await RepoSync.update(p.rootURL, token: token) {
            case .skipped(let reason): syncNotes[p.id] = reason
            case .upToDate, .updated: syncNotes[p.id] = nil
            }
        }
    }

    func indexAll() {
        for p in projects where p.lastIndex != nil { indexer.enqueue(p.id) }
    }

    // MARK: Onboarding

    /// First launch: a short tour before the empty library.
    var showOnboarding = false

    func finishOnboarding() {
        showOnboarding = false
        UserDefaults.standard.set(true, forKey: "onboardingDone")
    }

    /// Mapo's own source, shipped in the app, as a ready-made first map.
    /// Copied out of the bundle (read-only, signed) into the data folder.
    func openSample() async {
        guard let bundled = Bundle.main.url(forResource: "Sample", withExtension: nil)?.appendingPathComponent("Mapo") else {
            alert = AlertMessage(title: String(localized: "Örnek proje bulunamadı"), message: String(localized: "Bu Mapo sürümünde örnek proje yok."))
            return
        }
        let target = paths.base.appendingPathComponent("Sample/Mapo", isDirectory: true)
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: target.path) {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: bundled, to: target)
            }
        } catch {
            alert = AlertMessage(error: error)
            return
        }
        do {
            selection = try await library.add(folder: target, name: String(localized: "Örnek: Mapo")).id
        } catch ProjectLibrary.LibraryError.alreadyAdded(let id) {
            selection = id
        } catch {
            alert = AlertMessage(error: error)
            return
        }
        projects = await library.projects
        syncWatchers()
        if let id = selection, let p = projects.first(where: { $0.id == id }), p.lastIndex == nil { indexer.enqueue(id) }
    }

    /// Adds every folder in `urls`; reports the first failure, keeps going.
    func addFolders(_ urls: [URL]) async {
        var firstError: Error?
        var lastAdded: Project.ID?
        for url in urls {
            do {
                lastAdded = try await library.add(folder: url).id
            } catch ProjectLibrary.LibraryError.alreadyAdded(let id) {
                lastAdded = id
            } catch {
                firstError = firstError ?? error
            }
        }
        projects = await library.projects
        syncWatchers()
        if let lastAdded { selection = lastAdded }
        if let firstError { alert = AlertMessage(error: firstError) }
    }

    func workspace(for project: Project) -> Workspace {
        recent.removeAll { $0 == project.id }
        recent.append(project.id)
        if let ws = workspaces[project.id] { return ws }
        let ws = Workspace(project: project, paths: paths, indexer: indexer)
        workspaces[project.id] = ws
        while recent.count > warmWorkspaces {
            let old = recent.removeFirst()
            workspaces.removeValue(forKey: old)?.close()
        }
        return ws
    }

    private func save(_ project: Project) async {
        do {
            try await library.update(project)
            projects = await library.projects
            await refreshStatus(project)
        } catch {
            alert = AlertMessage(error: error)
        }
    }

    /// Recomputes the sidebar status dots (cheap: one git call per project).
    func refreshStatuses() async {
        await withTaskGroup(of: Void.self) { group in
            for p in projects { group.addTask { await self.refreshStatus(p) } }
        }
    }

    private func refreshStatus(_ project: Project) async {
        guard let commit = project.lastIndex?.commit else { behind[project.id] = nil; return }
        guard let head = await GitInfo.head(at: project.rootURL) else { behind[project.id] = nil; return }
        behind[project.id] = head.commit == commit ? 0 : await GitInfo.commitsSince(commit, at: project.rootURL)
    }

    func remove(_ id: Project.ID) async {
        indexer.cancel(id)
        watchers.removeValue(forKey: id)?.stop()
        workspaces.removeValue(forKey: id)?.close()
        recent.removeAll { $0 == id }
        do {
            try await library.remove(id)
            projects = await library.projects
            if selection == id { selection = projects.first?.id }
        } catch {
            alert = AlertMessage(error: error)
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        try? await library.move(fromOffsets: source, toOffset: destination)
        projects = await library.projects
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    init(error: Error) {
        title = String(localized: "Bir sorun oldu")
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
