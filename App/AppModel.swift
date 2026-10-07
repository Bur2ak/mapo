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

    func remove(_ id: Project.ID) async {
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
