import AtlasCore
import Foundation
import Observation

/// Window-independent app state: the project library and what is selected.
@MainActor
@Observable
final class AppModel {
    private(set) var projects: [Project] = []
    var selection: Project.ID?
    /// Last user-facing error, shown as an alert.
    var alert: AlertMessage?

    let paths: AtlasPaths
    private let library: ProjectLibrary
    /// Open workspaces, most recently used last. A few stay warm so switching
    /// projects is instant; older ones are closed.
    @ObservationIgnored private var workspaces: [Project.ID: Workspace] = [:]
    @ObservationIgnored private var recent: [Project.ID] = []
    private let warmWorkspaces = 3

    init(paths: AtlasPaths = .standard) {
        self.paths = paths
        self.library = ProjectLibrary(paths: paths)
    }

    var selectedProject: Project? {
        projects.first { $0.id == selection }
    }

    func start() async {
        do {
            try await library.load()
            projects = await library.projects
            if selection == nil { selection = projects.first?.id }
        } catch {
            alert = AlertMessage(error: error)
        }
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
        if let lastAdded { selection = lastAdded }
        if let firstError { alert = AlertMessage(error: firstError) }
    }

    func workspace(for project: Project) -> Workspace {
        recent.removeAll { $0 == project.id }
        recent.append(project.id)
        if let ws = workspaces[project.id] { return ws }
        let ws = Workspace(project: project, paths: paths) { [weak self] updated in
            Task { await self?.save(updated) }
        }
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
        } catch {
            alert = AlertMessage(error: error)
        }
    }

    func remove(_ id: Project.ID) async {
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
