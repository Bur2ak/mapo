import Foundation
import Testing
@testable import AtlasCore

@Suite("Değişiklik süzgeci")
struct ChangeFilterTests {
    let root = "/Users/x/proje"

    @Test func sourceFiles() {
        #expect(ChangeFilter.classify("/Users/x/proje/apps/mobile/lib/api.ts", root: root) == .source("apps/mobile/lib/api.ts"))
        #expect(ChangeFilter.classify("/Users/x/proje/App/Workspace.swift", root: root) == .source("App/Workspace.swift"))
        #expect(ChangeFilter.classify("/Users/x/proje/.github/workflows/build.sh", root: root) == .source(".github/workflows/build.sh"))
    }

    @Test func noiseIsIgnored() {
        for p in [
            "/Users/x/proje/node_modules/react/index.js",
            "/Users/x/proje/apps/mobile/node_modules/x/y.ts",
            "/Users/x/proje/build/Build/Products/a.swift",
            "/Users/x/proje/.expo/cache.json",
            "/Users/x/proje/README.md",
            "/Users/x/proje/assets/logo.png",
            "/Users/x/proje/src/.DS_Store",
            "/Users/x/proje/src/.api.ts.swp",
            "/Users/x/proje/.git/index",
            "/Users/x/proje/.git/objects/ab/cdef",
            "/Users/x/baska/a.ts",
            "/Users/x/proje-2/a.ts",
        ] {
            #expect(ChangeFilter.classify(p, root: root) == .ignored, "\(p)")
        }
    }

    @Test func gitEvents() {
        #expect(ChangeFilter.classify("/Users/x/proje/.git/HEAD", root: root) == .git)
        #expect(ChangeFilter.classify("/Users/x/proje/.git/refs/heads/ozellik/sosyal", root: root) == .git)
        #expect(ChangeFilter.classify("/Users/x/proje/.git/refs/remotes/origin/main", root: root) == .git)
        #expect(ChangeFilter.classify("/Users/x/proje/.git/packed-refs", root: root) == .git)
        #expect(ChangeFilter.classify("/Users/x/proje/.git/refs/tags/v1", root: root) == .ignored)
    }

    @Test func rootWithTrailingSlash() {
        #expect(ChangeFilter.classify("/Users/x/proje/a.ts", root: "/Users/x/proje/") == .source("a.ts"))
    }
}

@Suite("İzleyici", .serialized)
struct WatcherTests {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var changes: [ProjectChange] = []
        func add(_ c: ProjectChange) { lock.lock(); changes.append(c); lock.unlock() }
        var all: [ProjectChange] { lock.lock(); defer { lock.unlock() }; return changes }
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        // Deliberately the /var (not /private/var) spelling: the watcher must
        // still match FSEvents' real paths.
        return d
    }

    private func waitFor(_ box: Box, count: Int, timeout: Double = 8) async {
        let end = Date().addingTimeInterval(timeout)
        while box.all.count < count, Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
    }

    @Test func burstBecomesOneChange() async throws {
        let dir = try tempDir()
        let box = Box()
        let w = ProjectWatcher(root: dir, quiet: 0.6) { box.add($0) }
        w.start()
        defer { w.stop() }
        try await Task.sleep(for: .milliseconds(400))

        for i in 0..<5 {
            try Data("let a\(i) = 1\n".utf8).write(to: dir.appendingPathComponent("src/f\(i).ts"))
            try await Task.sleep(for: .milliseconds(60))
        }
        try Data("x".utf8).write(to: dir.appendingPathComponent("node_modules/x/i.js"))
        try Data("# notlar".utf8).write(to: dir.appendingPathComponent("NOTLAR.md"))

        await waitFor(box, count: 1)
        try await Task.sleep(for: .milliseconds(900))
        let all = box.all
        #expect(all.count == 1)
        #expect(all.first?.files == Set((0..<5).map { "src/f\($0).ts" }))
        #expect(all.first?.git == false)
    }

    @Test func onlyNoiseNeverFires() async throws {
        let dir = try tempDir()
        let box = Box()
        let w = ProjectWatcher(root: dir, quiet: 0.4) { box.add($0) }
        w.start()
        defer { w.stop() }
        try await Task.sleep(for: .milliseconds(400))
        try Data("x".utf8).write(to: dir.appendingPathComponent("node_modules/x/i.js"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("README.md"))
        try await Task.sleep(for: .seconds(1.5))
        #expect(box.all.isEmpty)
    }

    @Test func stopSilences() async throws {
        let dir = try tempDir()
        let box = Box()
        let w = ProjectWatcher(root: dir, quiet: 0.3) { box.add($0) }
        w.start()
        try await Task.sleep(for: .milliseconds(300))
        w.stop()
        try Data("let a = 1".utf8).write(to: dir.appendingPathComponent("src/a.ts"))
        try await Task.sleep(for: .seconds(1.2))
        #expect(box.all.isEmpty)
    }
}
