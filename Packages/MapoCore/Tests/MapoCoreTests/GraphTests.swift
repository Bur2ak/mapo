import Foundation
import Testing
@testable import MapoCore

private func fixture(_ name: String) throws -> (Graph, GraphLoader.Metadata) {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try GraphLoader.load(from: url)
}

private func pos(_ g: Graph, _ id: String) throws -> Int {
    try #require(g.position(of: id), "düğüm yok: \(id)")
}

@Suite("Yükleme")
struct LoaderTests {
    @Test func metadataAndCounts() throws {
        let (g, meta) = try fixture("kucuk")
        #expect(meta.engineVersion == "0.9.79")
        #expect(meta.schemaVersion == 1)
        #expect(meta.builtAtCommit == "abc1234")
        // 12 raw nodes, one duplicate id → 11.
        #expect(g.nodes.count == 11)
        // 13 raw links, one dangling target → 12.
        #expect(g.edges.count == 12)
    }

    @Test func duplicateIdKeepsFirst() throws {
        let (g, _) = try fixture("kucuk")
        #expect(g.node("fn_ac")?.label == "kulupSohbetiAc()")
    }

    @Test func integerIdsAreAccepted() throws {
        let (g, _) = try fixture("kucuk")
        #expect(g.node("42")?.label == "Değişken")
        let refs = g.incoming[try pos(g, "fn_ac")].map { g.edges[$0].relation }
        #expect(refs.contains(.references))
    }

    @Test func kinds() throws {
        let (g, _) = try fixture("kucuk")
        #expect(g.node("f_kulup")?.kind == .file)
        #expect(g.node("f_sayfa")?.kind == .file)
        #expect(g.node("fn_ac")?.kind == .function)
        #expect(g.node("m_oda")?.kind == .method)
        #expect(g.node("c_sayfa")?.kind == .type)
        #expect(g.node("s_sinir")?.kind == .symbol)
        #expect(g.node("ext_react")?.kind == .external)
    }

    @Test func lineParsing() throws {
        #expect(GraphLoader.parseLine("L42") == 42)
        #expect(GraphLoader.parseLine("L449-L470") == 449)
        #expect(GraphLoader.parseLine("7") == 7)
        #expect(GraphLoader.parseLine("") == nil)
        #expect(GraphLoader.parseLine(nil) == nil)
        #expect(GraphLoader.parseLine("Lx") == nil)
    }

    @Test func unknownRelationAndConfidenceSurvive() throws {
        let (g, _) = try fixture("kucuk")
        let e = try #require(g.edges.first { $0.relation.rawValue == "yeni_iliski" })
        #expect(e.confidence == .inferred)
    }

    @Test func nameStripsCallSyntax() throws {
        let (g, _) = try fixture("kucuk")
        #expect(g.node("fn_ac")?.name == "kulupSohbetiAc")
        #expect(g.node("m_oda")?.name == "ozetiPlanla")
    }

    @Test func malformedFails() {
        #expect(throws: GraphLoader.LoadError.self) {
            _ = try GraphLoader.decode(Data("{\"nodes\": 3}".utf8))
        }
    }
}

@Suite("Sorgular")
struct QueryTests {
    @Test func callersAndCallees() throws {
        let (g, _) = try fixture("kucuk")
        let ac = try pos(g, "fn_ac")
        #expect(g.callers(of: ac).map { g.nodes[$0.node].id } == ["c_sayfa"])
        #expect(g.callees(of: ac).map { g.nodes[$0.node].id } == ["fn_ozel"])
    }

    @Test func importsAndChildren() throws {
        let (g, _) = try fixture("kucuk")
        let api = try pos(g, "f_api")
        #expect(g.importers(of: api).map { g.nodes[$0.node].id } == ["f_kulup"])
        #expect(Set(g.children(of: api).map { g.nodes[$0].id }) == ["fn_ozel", "fn_istek"])
        #expect(g.parent(of: try pos(g, "fn_ozel")).map { g.nodes[$0].id } == "f_api")
    }

    @Test func directedPath() throws {
        let (g, _) = try fixture("kucuk")
        let p = try #require(g.shortestPath(from: try pos(g, "c_sayfa"), to: try pos(g, "fn_istek")))
        #expect(p.directed)
        #expect(p.nodes.map { g.nodes[$0].id } == ["c_sayfa", "fn_ac", "fn_ozel", "fn_istek"])
        #expect(p.edges.count == 3)
    }

    @Test func undirectedFallback() throws {
        let (g, _) = try fixture("kucuk")
        // Nothing flows from the API helper back to the page.
        let p = try #require(g.shortestPath(from: try pos(g, "fn_istek"), to: try pos(g, "c_sayfa")))
        #expect(!p.directed)
        #expect(p.nodes.first == (try pos(g, "fn_istek")))
        #expect(p.nodes.last == (try pos(g, "c_sayfa")))
        #expect(g.shortestPath(from: try pos(g, "fn_istek"), to: try pos(g, "c_sayfa"), directed: true) == nil)
    }

    @Test func pathToSelf() throws {
        let (g, _) = try fixture("kucuk")
        let a = try pos(g, "fn_ac")
        #expect(g.shortestPath(from: a, to: a)?.nodes == [a])
    }

    @Test func impactRings() throws {
        let (g, _) = try fixture("kucuk")
        let rings = g.impact(of: try pos(g, "fn_istek"))
        let ids = rings.map { Set($0.map { g.nodes[$0].id }) }
        #expect(ids[0] == ["fn_istek"])
        #expect(ids[1] == ["fn_ozel"])
        #expect(ids[2] == ["fn_ac"])
        #expect(ids[3] == ["c_sayfa", "42"])
    }

    @Test func fileImpactIncludesSymbolDependents() throws {
        let (g, _) = try fixture("kucuk")
        let rings = g.impact(of: try pos(g, "f_api"), maxDepth: 1)
        let ring1 = Set(rings[1].map { g.nodes[$0].id })
        // f_kulup imports the file, fn_ac calls a symbol in it.
        #expect(ring1 == ["f_kulup", "fn_ac"])
    }

    @Test func externalPackageImpactReachesImporters() throws {
        let (g, _) = try fixture("kucuk")
        // Upgrading react touches the page that imports it.
        let rings = g.impact(of: try pos(g, "ext_react"), maxDepth: 1)
        #expect(Set(rings[1].map { g.nodes[$0].id }) == ["f_sayfa"])
    }

    @Test func externalsNeverListedAsDependents() throws {
        let (g, _) = try fixture("kucuk")
        for i in g.nodes.indices {
            let dependents = g.impact(of: i).dropFirst().flatMap { $0 }
            #expect(!dependents.contains { g.nodes[$0].kind == .external })
        }
    }

    @Test func fileDependenciesAggregateSymbols() throws {
        let (g, _) = try fixture("kucuk")
        let deps = g.fileDependencies(of: try pos(g, "f_kulup"))
        // kulupSohbet.ts uses api.ts twice (import + kulupSohbetiAc→kulupOzelSohbetAc)
        #expect(deps.uses.map { g.nodes[$0.file].id } == ["f_api"])
        #expect(deps.uses.first?.weight == 2)
        // used by the page (import + KulupSayfasi→kulupSohbetiAc) and by apps/x.ts (references)
        #expect(Set(deps.usedBy.map { g.nodes[$0.file].id }).contains("f_sayfa"))
        #expect(deps.usedBy.first { g.nodes[$0.file].id == "f_sayfa" }?.weight == 2)
    }

    @Test func nodesInFiles() throws {
        let (g, _) = try fixture("kucuk")
        let ids = Set(g.nodes(inFiles: ["apps/mobile/lib/api.ts"]).map { g.nodes[$0].id })
        #expect(ids == ["f_api", "fn_ozel", "fn_istek"])
    }
}

@Suite("Arama")
struct SearchTests {
    @Test func exactBeatsPartial() throws {
        let (g, _) = try fixture("kucuk")
        let hits = SearchIndex(graph: g).search("kulupSohbetiAc")
        #expect(g.nodes[try #require(hits.first).position].id == "fn_ac")
    }

    @Test func camelCaseInitials() throws {
        let (g, _) = try fixture("kucuk")
        let hits = SearchIndex(graph: g).search("kosa")
        #expect(g.nodes[try #require(hits.first).position].id == "fn_ozel")
    }

    @Test func turkishFolding() throws {
        let (g, _) = try fixture("kucuk")
        let index = SearchIndex(graph: g)
        #expect(index.search("kulüpsohbetiaç").first.map { g.nodes[$0.position].id } == "fn_ac")
        #expect(index.search("DEGISKEN").first.map { g.nodes[$0.position].id } == "42")
    }

    @Test func rangesPointAtMatchedCharacters() throws {
        let (g, _) = try fixture("kucuk")
        let hit = try #require(SearchIndex(graph: g).search("sayfa").first { g.nodes[$0.position].id == "c_sayfa" })
        // "KulupSayfasi": S at 5.
        #expect(hit.ranges == [5, 6, 7, 8, 9])
    }

    @Test func pathFallback() throws {
        let (g, _) = try fixture("kucuk")
        let hits = SearchIndex(graph: g).search("routes/kulup")
        #expect(hits.contains { g.nodes[$0.position].id == "s_sinir" })
    }

    @Test func externalsAreNotSearchable() throws {
        let (g, _) = try fixture("kucuk")
        #expect(SearchIndex(graph: g).search("react").isEmpty)
    }

    @Test func emptyAndNoMatch() throws {
        let (g, _) = try fixture("kucuk")
        let index = SearchIndex(graph: g)
        #expect(index.search("   ").isEmpty)
        #expect(index.search("zzzqqq").isEmpty)
    }

    @Test func dpPrefersBoundaryAlignment() {
        let s = Array("abcKulupSohbet")
        let (_, ranges) = SearchIndex.match(SearchIndex.fold(Array("ks")), in: SearchIndex.fold(s), boundaries: SearchIndex.boundaries(s))!
        // K at 3 and S at 8 (humps), not the first lowercase s.
        #expect(ranges == [3, 8])
    }
}

@Suite("Kütüphane")
struct LibraryTests {
    private func tempPaths() throws -> (MapoPaths, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-test-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("proje", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (MapoPaths(base: base.appendingPathComponent("support")), folder)
    }

    @Test func addPersistReload() async throws {
        let (paths, folder) = try tempPaths()
        let lib = ProjectLibrary(paths: paths)
        let p = try await lib.add(folder: folder)
        #expect(p.name == "proje")

        let again = ProjectLibrary(paths: paths)
        try await again.load()
        #expect(await again.projects.map(\.id) == [p.id])
    }

    @Test func rejectsDuplicatesAndFiles() async throws {
        let (paths, folder) = try tempPaths()
        let lib = ProjectLibrary(paths: paths)
        let p = try await lib.add(folder: folder)
        await #expect(throws: ProjectLibrary.LibraryError.alreadyAdded(p.id)) {
            try await lib.add(folder: folder)
        }
        let file = folder.appendingPathComponent("a.txt")
        try Data().write(to: file)
        await #expect(throws: ProjectLibrary.LibraryError.self) {
            try await lib.add(folder: file)
        }
    }

    @Test func removeDeletesOnlyMapoData() async throws {
        let (paths, folder) = try tempPaths()
        let lib = ProjectLibrary(paths: paths)
        let p = try await lib.add(folder: folder)
        try FileManager.default.createDirectory(at: paths.projectDir(p.id), withIntermediateDirectories: true)
        try await lib.remove(p.id)
        #expect(!FileManager.default.fileExists(atPath: paths.projectDir(p.id).path))
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(await lib.projects.isEmpty)
    }

    @Test func corruptLibraryIsMovedAside() async throws {
        let (paths, _) = try tempPaths()
        try FileManager.default.createDirectory(at: paths.base, withIntermediateDirectories: true)
        try Data("bozuk{".utf8).write(to: paths.libraryFile)
        let lib = ProjectLibrary(paths: paths)
        try await lib.load()
        #expect(await lib.projects.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.base.path)
        #expect(names.contains { $0.contains("bozuk-") })
    }

    @Test func reorder() async throws {
        let (paths, folder) = try tempPaths()
        let lib = ProjectLibrary(paths: paths)
        var made: [UUID] = []
        for n in ["a", "b", "c"] {
            let f = folder.appendingPathComponent(n)
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            made.append(try await lib.add(folder: f).id)
        }
        try await lib.move(fromOffsets: [0], toOffset: 3)
        #expect(await lib.projects.map(\.id) == [made[1], made[2], made[0]])
        try await lib.move(fromOffsets: [2], toOffset: 0)
        #expect(await lib.projects.map(\.id) == made)
    }
}

/// Real-world graph (Kontak, ~4k nodes / ~13k edges). Skipped when absent.
private let realGraphPath = ProcessInfo.processInfo.environment["MAPO_REAL_GRAPH"]
    ?? NSHomeDirectory() + "/Projeler/KONTAK/graf-cikti/graphify-out/graph.json"

@Suite("Gerçek graf", .enabled(if: FileManager.default.fileExists(atPath: realGraphPath)))
struct RealGraphTests {
    @Test func loadsFastAndAnswers() throws {
        let clock = ContinuousClock()
        var loaded: (Graph, GraphLoader.Metadata)?
        let loadTime = try clock.measure { loaded = try GraphLoader.load(from: URL(fileURLWithPath: realGraphPath)) }
        let (g, _) = try #require(loaded)
        #expect(g.nodes.count > 1000)
        #expect(loadTime < .seconds(2), "yükleme \(loadTime)")

        var index: SearchIndex?
        let indexTime = clock.measure { index = SearchIndex(graph: g) }
        #expect(indexTime < .seconds(1), "dizin \(indexTime)")

        var hits: [SearchIndex.Hit] = []
        let searchTime = clock.measure { hits = index!.search("kulupSohbetiAc") }
        #expect(searchTime < .milliseconds(80), "arama \(searchTime)")
        let top = g.nodes[try #require(hits.first).position]
        #expect(top.name == "kulupSohbetiAc")

        let callees = Set(g.callees(of: try #require(g.position(of: top.id))).map { g.nodes[$0.node].name })
        #expect(callees.isSuperset(of: ["kulupOzelSohbetAc", "taslakSatirKaydet"]))
    }
}
