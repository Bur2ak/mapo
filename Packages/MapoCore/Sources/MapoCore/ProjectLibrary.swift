import Foundation

/// The user's list of projects, persisted as `library.json`.
///
/// Writes are atomic (temp file + rename) so a crash mid-save never leaves a
/// truncated library. A corrupt file is moved aside, never silently erased.
public actor ProjectLibrary {
    public private(set) var projects: [Project] = []
    private let paths: MapoPaths
    private let fm = FileManager.default

    public init(paths: MapoPaths) {
        self.paths = paths
    }

    public enum LibraryError: Error, LocalizedError, Equatable {
        case notADirectory(String)
        case alreadyAdded(UUID)

        public var errorDescription: String? {
            switch self {
            case .notADirectory(let p): String(localized: "Bu bir klasör değil: \(p)")
            case .alreadyAdded: String(localized: "Bu proje zaten kütüphanede.")
            }
        }
    }

    public func load() throws {
        guard fm.fileExists(atPath: paths.libraryFile.path) else { projects = []; return }
        let data = try Data(contentsOf: paths.libraryFile)
        do {
            projects = try Self.decoder.decode(Stored.self, from: data).projects
        } catch {
            let aside = paths.libraryFile.deletingPathExtension()
                .appendingPathExtension("bozuk-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: paths.libraryFile, to: aside)
            projects = []
        }
    }

    @discardableResult
    public func add(folder url: URL, name: String? = nil, source: Project.Source = .folder) throws -> Project {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw LibraryError.notADirectory(root.path)
        }
        if let existing = projects.first(where: { $0.rootPath == root.path }) {
            throw LibraryError.alreadyAdded(existing.id)
        }
        let project = Project(name: name ?? root.lastPathComponent, rootPath: root.path, source: source)
        projects.append(project)
        try save()
        return project
    }

    public func update(_ project: Project) throws {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[i] = project
        try save()
    }

    /// Removes the project and Mapo's data for it. Never touches the
    /// project's own folder.
    public func remove(_ id: UUID) throws {
        projects.removeAll { $0.id == id }
        try save()
        let dir = paths.projectDir(id)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        let moving = source.map { projects[$0] }
        let insertAt = destination - source.count(in: 0..<destination)
        for i in source.reversed() { projects.remove(at: i) }
        projects.insert(contentsOf: moving, at: insertAt)
        try save()
    }

    private func save() throws {
        try fm.createDirectory(at: paths.base, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(Stored(version: 1, projects: projects))
        try data.write(to: paths.libraryFile, options: .atomic)
    }

    private struct Stored: Codable {
        var version: Int
        var projects: [Project]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
