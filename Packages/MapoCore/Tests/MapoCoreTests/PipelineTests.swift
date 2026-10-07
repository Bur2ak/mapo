import Foundation
import Testing
@testable import MapoCore

@Suite("Harita verisi")
struct MapPayloadTests {
    private func graph() throws -> Graph {
        let url = try #require(Bundle.module.url(forResource: "kucuk", withExtension: "json", subdirectory: "Fixtures"))
        return try GraphLoader.load(from: url).0
    }

    @Test func columnsAreAligned() throws {
        let g = try graph()
        let p = MapPayload(graph: g)
        let n = g.nodes.count
        #expect([p.nodes.id.count, p.nodes.label.count, p.nodes.kind.count, p.nodes.community.count,
                 p.nodes.folder.count, p.nodes.test.count, p.nodes.degree.count].allSatisfy { $0 == n })
        #expect(p.edges.s.count == g.edges.count && p.edges.t.count == g.edges.count && p.edges.r.count == g.edges.count)
        #expect(p.edges.s.allSatisfy { $0 >= 0 && $0 < n })
        #expect(p.edges.t.allSatisfy { $0 >= 0 && $0 < n })
        #expect(p.nodes.folder.allSatisfy { $0 >= 0 && $0 < p.folders.count })
    }

    @Test func labelsAndCodes() throws {
        let g = try graph()
        let p = MapPayload(graph: g)
        let i = try #require(g.position(of: "fn_ac"))
        #expect(p.nodes.label[i] == "kulupSohbetiAc")
        #expect(p.nodes.kind[i] == 1)
        let f = try #require(g.position(of: "f_api"))
        #expect(p.nodes.label[f] == "api.ts")
        #expect(p.nodes.kind[f] == 0)
        // contains → 0, calls → 1, imports_from → 2, references → 3
        let rels = Dictionary(grouping: g.edges.indices, by: { g.edges[$0].relation }).mapValues { p.edges.r[$0[0]] }
        #expect(rels[.contains] == 0)
        #expect(rels[.calls] == 1)
        #expect(rels[.importsFrom] == 2)
        #expect(rels[.references] == 3)
    }

    @Test func degreeIgnoresContainment() throws {
        let g = try graph()
        let p = MapPayload(graph: g)
        // f_api: contains×2 (ignored) + imported by f_kulup (1)
        #expect(p.nodes.degree[try #require(g.position(of: "f_api"))] == 1)
    }

    @Test func communityNamesUseHub() throws {
        let g = try graph()
        let names = MapPayload.communityNames(g)
        // community 2 = {api.ts, kulupOzelSohbetAc, istek}; api.ts has most edges → "api"
        #expect(names[2] == "api")
        #expect(names.count == 5)
    }

    @Test func encodesAsJSON() throws {
        let data = try MapPayload(graph: try graph(), positions: ["fn_ac": [1.5, -2]]).encoded()
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["version"] as? Int == 1)
        #expect((obj["positions"] as? [String: [Double]])?["fn_ac"] == [1.5, -2])
    }

    @Test func fileLinksLiftSymbolEdges() throws {
        let g = try graph()
        let links = MapPayload.fileLinks(g)
        var pairs: [String: Int] = [:]
        for i in links.s.indices {
            pairs["\(g.nodes[links.s[i]].id)>\(g.nodes[links.t[i]].id)"] = links.w[i]
        }
        // kulupSohbet.ts → api.ts: import edge + kulupSohbetiAc() calls kulupOzelSohbetAc()
        #expect(pairs["f_kulup>f_api"] == 2)
        // [id].tsx → kulupSohbet.ts: import + KulupSayfasi calls kulupSohbetiAc
        #expect(pairs["f_sayfa>f_kulup"] == 2)
        // Same-file calls (kulupOzelSohbetAc → istek in api.ts) never self-link.
        #expect(!pairs.keys.contains { $0.hasPrefix("f_api>f_api") })
        // Containment is structure, not a dependency.
        #expect(links.s.indices.allSatisfy { links.s[$0] != links.t[$0] })
    }

    @Test func folderGroupingKeepsSmallSplitsWhole() {
        // App/Views is big, App/Map and App/Design are crumbs → "App" stays one area.
        var files = (0..<5).map { "App/f\($0).swift" } + (0..<7).map { "App/Views/v\($0).swift" }
        files += ["App/Map/m.swift", "App/Design/d.swift"] + (0..<13).map { "Packages/Core/p\($0).swift" }
        let g = FolderGrouping(files: files)
        #expect(g.group(of: "App/Views/v1.swift") == "App")
        #expect(g.group(of: "App/Map/m.swift") == "App")
        #expect(g.group(of: "Packages/Core/p1.swift") == "Packages")
    }

    @Test func groupingCountsFilesNotSymbols() {
        // 1 file with 200 symbols must weigh like 1 file.
        var nodes = [Node(id: "a", label: "a.swift", kind: .file, sourceFile: "App/a.swift", line: 1, community: 0)]
        nodes += (0..<200).map { Node(id: "v\($0)", label: "f\($0)()", kind: .function, sourceFile: "App/Views/big.swift", line: $0, community: 0) }
        nodes += (0..<200).map { Node(id: "m\($0)", label: "g\($0)()", kind: .function, sourceFile: "App/Map/big.swift", line: $0, community: 0) }
        nodes += (0..<20).map { Node(id: "p\($0)", label: "p\($0).swift", kind: .file, sourceFile: "Packages/Core/p\($0).swift", line: 1, community: 0) }
        let p = MapPayload(graph: Graph(nodes: nodes, edges: []))
        #expect(p.folders.contains("App"))
        #expect(!p.folders.contains("App/Views"))
    }

    @Test func subgroupsSkipRouteGroupsAndHelpers() {
        let g = FolderGrouping(files: ["apps/mobile/a.ts", "apps/mobile/b/c.ts", "apps/api/src/x/y.ts", "apps/api/z.ts"])
        #expect(g.subgroup(of: "apps/mobile/app/(sekmeler)/kesfet/index.tsx", in: "apps/mobile") == "kesfet")
        #expect(g.subgroup(of: "apps/mobile/lib/store/slice.ts", in: "apps/mobile") == "store")
        #expect(g.subgroup(of: "apps/api/src/routes/kulup.ts", in: "apps/api") == "routes")
        #expect(g.subgroup(of: "apps/mobile/a.ts", in: "apps/mobile") == "")
        #expect(g.subgroup(of: "README.md", in: "/") == "")
    }

    @Test func noiseFilter() {
        #expect(NoiseFilter.isNoise(path: "Map/package.json"))
        #expect(NoiseFilter.isNoise(path: "web/dist/app.js"))
        #expect(NoiseFilter.isNoise(path: "a/b/vendor.min.js"))
        #expect(NoiseFilter.isNoise(path: "types/global.d.ts"))
        #expect(!NoiseFilter.isNoise(path: "apps/mobile/lib/api.ts"))
        #expect(!NoiseFilter.isNoise(path: "src/builder.ts"))
    }

    @Test func minifiedDetection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-min-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundle = dir.appendingPathComponent("map.js")
        try Data(String(repeating: "var a=1;", count: 2_000).utf8).write(to: bundle)
        let source = dir.appendingPathComponent("main.js")
        try Data(String(repeating: "const a = 1;\n", count: 2_000).utf8).write(to: source)
        #expect(NoiseFilter.looksMinified(bundle))
        #expect(!NoiseFilter.looksMinified(source))
        #expect(!NoiseFilter.looksMinified(dir.appendingPathComponent("yok.js")))
    }

    @Test func noiseAndSubColumns() throws {
        let g = try graph()
        let p = MapPayload(graph: g, noisyFiles: ["apps/mobile/lib/api.ts"])
        #expect(p.nodes.noise.count == g.nodes.count && p.nodes.sub.count == g.nodes.count)
        #expect(p.nodes.noise[try #require(g.position(of: "f_api"))] == 1)
        #expect(p.nodes.noise[try #require(g.position(of: "f_kulup"))] == 0)
        #expect(p.nodes.sub.allSatisfy { $0 >= 0 && $0 < p.subfolders.count })
    }

    @Test func testPathDetection() {
        #expect(MapPayload.isTestPath("apps/mobile/__tests__/a.test.tsx"))
        #expect(MapPayload.isTestPath("src/foo.spec.ts"))
        #expect(MapPayload.isTestPath("Packages/MapoCore/Tests/MapoCoreTests/GraphTests.swift"))
        #expect(MapPayload.isTestPath("tests/test_x.py"))
        #expect(!MapPayload.isTestPath("apps/mobile/lib/testere.ts"))
        #expect(!MapPayload.isTestPath("apps/api/src/routes/kulup.ts"))
    }

    @Test func folderGroupingSplitsDominantRoot() {
        let files = [
            "apps/mobile/a.ts", "apps/mobile/b.ts", "apps/mobile/x/c.ts",
            "apps/api/src/d.ts", "apps/api/src/e.ts",
            "betikler/kur.mjs", "README.md",
        ]
        let g = FolderGrouping(files: files)
        #expect(g.group(of: "apps/mobile/x/c.ts") == "apps/mobile")
        #expect(g.group(of: "apps/api/src/d.ts") == "apps/api")
        #expect(g.group(of: "betikler/kur.mjs") == "betikler")
        #expect(g.group(of: "README.md") == "/")
    }
}

@Suite("Motor")
struct EngineTests {
    @Test func progressParsing() {
        #expect(Engine.parseProgress("  AST extraction: 100/562 uncached files (17%) [10 workers]")! == (100, 562))
        #expect(Engine.parseProgress("AST extraction: 562/562")! == (562, 562))
        #expect(Engine.parseProgress("[graphify extract] AST extraction on 562 code files...") == nil)
        #expect(Engine.parseProgress("AST extraction: 3/0") == nil)
        #expect(Engine.parseProgress("random") == nil)
    }

    @Test func stalledEngineIsStopped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("graphify")
        try "#!/bin/sh\nsleep 60\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var engine = Engine(executable: fake)
        engine.inactivityTimeout = .seconds(1)
        let started = ContinuousClock.now
        await #expect(throws: Engine.EngineError.stalled(step: "extract")) {
            try await engine.index(root: dir, output: dir.appendingPathComponent("out"), logName: "t") { _ in }
        }
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    @Test func childEnvironmentHasNoAPIKeys() async throws {
        setenv("ANTHROPIC_API_KEY", "sahte-anahtar", 1)
        setenv("OPENAI_API_KEY", "sahte-anahtar", 1)
        defer { unsetenv("ANTHROPIC_API_KEY"); unsetenv("OPENAI_API_KEY") }
        let r = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: ProcessRunner.cleanEnvironment()
        )
        #expect(r.status == 0)
        #expect(!r.stdout.contains("API_KEY"))
        #expect(!r.stdout.contains("sahte-anahtar"))
        #expect(r.stdout.contains("HOME="))
    }

    @Test func liveLinesSplitOnCarriageReturn() async throws {
        let lines = LineBox()
        let r = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'a\\rb\\nc'; printf 'hata' >&2; exit 3"],
            environment: ProcessRunner.cleanEnvironment()
        ) { lines.add($0) }
        #expect(r.status == 3)
        #expect(r.stderr == "hata")
        // Both streams are reported (graphify prints progress on stderr too), never spliced.
        #expect(lines.all == ["a", "b", "c", "hata"])
    }

    @Test func cancellationTerminates() async throws {
        let started = ContinuousClock.now
        let task = Task {
            try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                environment: ProcessRunner.cleanEnvironment()
            )
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let r = try await task.value
        #expect(r.status != 0)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/yok/boyle/bir/sey"),
                arguments: [],
                environment: [:]
            )
        }
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

@Suite("Git")
struct GitTests {
    private func sh(_ cmd: String, in dir: URL) async throws {
        let r = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", cmd],
            environment: ProcessRunner.cleanEnvironment(extra: [
                "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
            ]),
            currentDirectory: dir
        )
        try #require(r.status == 0, "\(cmd): \(r.stderr)")
    }

    @Test func headCountsAndChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(await GitInfo.head(at: dir) == nil)

        try await sh("git init -q -b ana && echo 1 > a.txt && git add . && git commit -qm bir", in: dir)
        let first = try #require(await GitInfo.head(at: dir))
        #expect(first.branch == "ana")
        #expect(first.commit.count == 40)

        try await sh("echo 2 > b.txt && git add . && git commit -qm iki && echo 3 > c.txt && git add . && git commit -qm uc", in: dir)
        #expect(await GitInfo.commitsSince(first.commit, at: dir) == 2)
        #expect(await GitInfo.commitsSince("deadbeef", at: dir) == nil)
        #expect(await GitInfo.commitsSince("; rm -rf /", at: dir) == nil)

        try await sh("echo x > a.txt && echo y > yeni.txt", in: dir)
        let changed = await GitInfo.recentlyChangedFiles(at: dir, commits: 1)
        #expect(changed == ["c.txt", "a.txt", "yeni.txt"])
    }
}
