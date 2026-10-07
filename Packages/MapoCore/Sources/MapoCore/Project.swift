import Foundation

/// A codebase the user added to Mapo.
public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Root folder on disk. Stored as a path; security-scoped bookmarks are
    /// not needed because Mapo ships outside the App Store sandbox (PLAN §4).
    public var rootPath: String
    public var addedAt: Date
    public var source: Source
    public var lastIndex: IndexRecord?

    public enum Source: Codable, Sendable, Hashable {
        case folder
        case github(owner: String, repo: String)
    }

    public struct IndexRecord: Codable, Sendable, Hashable {
        public var finishedAt: Date
        public var commit: String?
        public var branch: String?
        public var engineVersion: String?
        public var nodeCount: Int
        public var edgeCount: Int
        public var fileCount: Int

        public init(finishedAt: Date, commit: String?, branch: String?, engineVersion: String?, nodeCount: Int, edgeCount: Int, fileCount: Int) {
            self.finishedAt = finishedAt
            self.commit = commit
            self.branch = branch
            self.engineVersion = engineVersion
            self.nodeCount = nodeCount
            self.edgeCount = edgeCount
            self.fileCount = fileCount
        }
    }

    public init(id: UUID = UUID(), name: String, rootPath: String, addedAt: Date = .now, source: Source = .folder, lastIndex: IndexRecord? = nil) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.addedAt = addedAt
        self.source = source
        self.lastIndex = lastIndex
    }

    public var rootURL: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }
}

/// Where Mapo keeps its own data. Nothing is ever written inside a project.
public struct MapoPaths: Sendable {
    public let base: URL

    public init(base: URL) { self.base = base }

    /// `~/Library/Application Support/Mapo`
    public static var standard: MapoPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return MapoPaths(base: support.appendingPathComponent("Mapo", isDirectory: true))
    }

    public var libraryFile: URL { base.appendingPathComponent("library.json") }
    public var projectsDir: URL { base.appendingPathComponent("Projects", isDirectory: true) }
    public var reposDir: URL { base.appendingPathComponent("Repos", isDirectory: true) }

    public func projectDir(_ id: UUID) -> URL {
        projectsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// graphify writes `<out>/graphify-out/graph.json`.
    public func engineOutput(_ id: UUID) -> URL { projectDir(id) }

    public func graphFile(_ id: UUID) -> URL {
        projectDir(id).appendingPathComponent("graphify-out/graph.json")
    }
}
