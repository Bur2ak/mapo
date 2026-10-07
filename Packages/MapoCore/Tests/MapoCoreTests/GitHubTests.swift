import Foundation
import Testing
@testable import MapoCore

/// Scripted HTTP responses keyed by URL path, served in order.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script: [String: [(Int, [String: String], Data)]] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    static func reset() { lock.lock(); script = [:]; requests = []; lock.unlock() }
    static func add(_ path: String, status: Int = 200, headers: [String: String] = [:], json: Any) {
        lock.lock(); defer { lock.unlock() }
        let data = try! JSONSerialization.data(withJSONObject: json)
        script[path, default: []].append((status, headers, data))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open(); var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: 4096); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close(); req.httpBody = data
        }
        Self.requests.append(req)
        let path = request.url!.path
        let next = Self.script[path]?.isEmpty == false ? Self.script[path]!.removeFirst() : (404, [:], Data("{}".utf8))
        Self.lock.unlock()
        let resp = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: nil, headerFields: next.1)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.2)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: c)
    }
}

@Suite("GitHub", .serialized)
struct GitHubTests {
    private func auth() -> GitHubAuth {
        GitHubAuth(session: MockURLProtocol.session, clientID: "test-client", sleep: { _ in })
    }

    @Test func deviceCodeParsing() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.add("/login/device/code", json: [
            "device_code": "dc", "user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device",
            "expires_in": 900, "interval": 5,
        ])
        let code = try await auth().requestCode()
        #expect(code.userCode == "ABCD-1234")
        #expect(code.interval == 5)
        let body = String(decoding: MockURLProtocol.requests[0].httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("client_id=test-client"))
        #expect(body.contains("scope=repo%20read%3Aorg"))
    }

    @Test func pollingHandlesPendingSlowDownThenToken() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.add("/login/oauth/access_token", json: ["error": "authorization_pending"])
        MockURLProtocol.add("/login/oauth/access_token", json: ["error": "slow_down", "interval": 10])
        MockURLProtocol.add("/login/oauth/access_token", json: [
            "access_token": "ghu_x", "expires_in": 28800, "refresh_token": "ghr_y", "refresh_token_expires_in": 15_897_600,
        ])
        let intervals = IntervalBox()
        let a = GitHubAuth(session: MockURLProtocol.session, clientID: "c", sleep: { intervals.add($0) })
        let code = GitHub.DeviceCode(deviceCode: "dc", userCode: "U", verificationURL: URL(string: "https://x")!,
                                     expiresAt: .now.addingTimeInterval(600), interval: 5)
        let token = try await a.waitForToken(code)
        #expect(token.accessToken == "ghu_x")
        #expect(token.refreshToken == "ghr_y")
        #expect(token.expiresAt != nil && !token.isExpired)
        #expect(intervals.all == [5, 5, 10])
    }

    @Test func deniedAndExpired() async throws {
        let code = GitHub.DeviceCode(deviceCode: "dc", userCode: "U", verificationURL: URL(string: "https://x")!,
                                     expiresAt: .now.addingTimeInterval(600), interval: 1)
        MockURLProtocol.reset()
        MockURLProtocol.add("/login/oauth/access_token", json: ["error": "access_denied"])
        await #expect(throws: GitHub.AuthError.denied) { _ = try await auth().waitForToken(code) }

        MockURLProtocol.reset()
        MockURLProtocol.add("/login/oauth/access_token", json: ["error": "expired_token"])
        await #expect(throws: GitHub.AuthError.expired) { _ = try await auth().waitForToken(code) }

        let old = GitHub.DeviceCode(deviceCode: "dc", userCode: "U", verificationURL: URL(string: "https://x")!,
                                    expiresAt: .now.addingTimeInterval(-1), interval: 1)
        await #expect(throws: GitHub.AuthError.expired) { _ = try await auth().waitForToken(old) }
    }

    @Test func refresh() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.add("/login/oauth/access_token", json: ["access_token": "new", "expires_in": 100, "refresh_token": "r2"])
        let t = GitHub.Token(accessToken: "old", expiresAt: .now, refreshToken: "r1", refreshExpiresAt: .now.addingTimeInterval(100))
        let fresh = try await auth().refresh(t)
        #expect(fresh?.accessToken == "new")
        let body = String(decoding: MockURLProtocol.requests[0].httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token") && body.contains("refresh_token=r1"))

        MockURLProtocol.reset()
        MockURLProtocol.add("/login/oauth/access_token", json: ["error": "bad_refresh_token"])
        #expect(try await auth().refresh(t) == nil)
        let deadRefresh = GitHub.Token(accessToken: "x", expiresAt: .now, refreshToken: "r", refreshExpiresAt: .now.addingTimeInterval(-5))
        #expect(try await auth().refresh(deadRefresh) == nil)
    }

    @Test func errorDescriptionsNeverLeakTokens() {
        let d = GitHubAuth.describe(["access_token": "SECRET", "foo": 1])
        #expect(!d.contains("SECRET"))
    }

    @Test func repositoriesPaginateAndSort() async throws {
        MockURLProtocol.reset()
        func repo(_ id: Int, _ name: String, _ pushed: String, priv: Bool = false) -> [String: Any] {
            ["id": id, "name": name, "full_name": "o/\(name)", "owner": ["login": "o"], "private": priv,
             "default_branch": "main", "pushed_at": pushed, "clone_url": "https://github.com/o/\(name).git"]
        }
        MockURLProtocol.add("/user/repos", headers: ["Link": "<https://api.github.com/user/repos?page=2>; rel=\"next\", <https://api.github.com/user/repos?page=2>; rel=\"last\""],
                            json: [repo(1, "eski", "2025-01-01T00:00:00Z")])
        MockURLProtocol.add("/user/repos", json: [repo(2, "yeni", "2026-10-01T00:00:00Z", priv: true)])
        let repos = try await GitHubAPI(token: "t", session: MockURLProtocol.session).repositories()
        #expect(repos.map(\.name) == ["yeni", "eski"])
        #expect(repos[0].isPrivate)
        #expect(MockURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer t" })
    }

    @Test func unauthorizedIsDistinct() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.add("/user", status: 401, json: ["message": "Bad credentials"])
        await #expect(throws: GitHub.APIError.unauthorized) {
            _ = try await GitHubAPI(token: "t", session: MockURLProtocol.session).user()
        }
    }

    @Test func linkHeader() {
        #expect(GitHubAPI.nextPage(nil) == nil)
        #expect(GitHubAPI.nextPage("<https://a/x?page=3>; rel=\"last\"") == nil)
        #expect(GitHubAPI.nextPage("<https://a/x?page=1>; rel=\"prev\", <https://a/x?page=3>; rel=\"next\"")?.absoluteString == "https://a/x?page=3")
    }
}

private final class IntervalBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: [TimeInterval] = []
    func add(_ x: TimeInterval) { lock.lock(); v.append(x); lock.unlock() }
    var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return v }
}

@Suite("Anahtar Zinciri")
struct KeychainTests {
    @Test func roundTrip() throws {
        let k = Keychain(service: "io.github.bur2ak.mapo.tests-\(UUID().uuidString)")
        defer { try? k.delete(account: "a") }
        #expect(try k.get(account: "a") == nil)
        try k.set(Data("bir".utf8), account: "a")
        try k.set(Data("iki".utf8), account: "a")
        #expect(try k.get(account: "a") == Data("iki".utf8))
        try k.delete(account: "a")
        #expect(try k.get(account: "a") == nil)
        try k.delete(account: "a")
    }
}

@Suite("Depo eşitleme", .serialized)
struct RepoSyncTests {
    private func sh(_ cmd: String, _ dir: URL) async throws {
        let r = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", cmd],
            environment: ProcessRunner.cleanEnvironment(extra: ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]),
            currentDirectory: dir)
        try #require(r.status == 0, "\(cmd): \(r.stderr)")
    }

    @Test func cloneThenFastForward() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-sync-\(UUID().uuidString)")
        let origin = base.appendingPathComponent("origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try await sh("git init -q -b main && echo 1 > a.ts && git add . && git commit -qm bir", origin)

        let clone = base.appendingPathComponent("clones/o/proje")
        try await RepoSync.clone(origin, to: clone, token: nil)
        #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent("a.ts").path))
        await #expect(throws: RepoSync.SyncError.self) { try await RepoSync.clone(origin, to: clone, token: nil) }

        #expect(await RepoSync.update(clone, token: nil) == .upToDate)

        try await sh("echo 2 > b.ts && git add . && git commit -qm iki && echo 3 > c.ts && git add . && git commit -qm uc", origin)
        #expect(await RepoSync.update(clone, token: nil) == .updated(commits: 2))
        #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent("c.ts").path))

        // Dirty work tree: untouched.
        try await sh("echo 4 > d.ts && git add . && git commit -qm dort", origin)
        try "değişti".write(to: clone.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)
        if case .skipped = await RepoSync.update(clone, token: nil) {} else { Issue.record("kirli ağaç güncellenmemeliydi") }
        #expect(!FileManager.default.fileExists(atPath: clone.appendingPathComponent("d.ts").path))

        // Local commit: diverged, untouched.
        try await sh("git commit -qam yerel", clone)
        if case .skipped = await RepoSync.update(clone, token: nil) {} else { Issue.record("ayrışmış dal güncellenmemeliydi") }
    }

    @Test func tokenOnlyInEnvironment() throws {
        let env = RepoSync.environment(token: "ghu_SECRET")
        let n = try #require(Int(env["GIT_CONFIG_COUNT"] ?? ""))
        let pairs = (0..<n).map { (env["GIT_CONFIG_KEY_\($0)"]!, env["GIT_CONFIG_VALUE_\($0)"]!) }
        let header = try #require(pairs.first { $0.0 == "http.https://github.com/.extraHeader" })
        #expect(header.1.hasPrefix("Authorization: Basic "))
        #expect(!env.values.contains { $0.contains("ghu_SECRET") })
        // Without a token: only the safety settings.
        let plain = RepoSync.environment(token: nil)
        #expect(plain["GIT_CONFIG_COUNT"] == "\(ProcessRunner.gitSafety.count)")
        #expect(!plain.values.contains { $0.hasPrefix("Authorization") })
        #expect(RepoSync.redact("fatal: ghu_SECRET bad", token: "ghu_SECRET") == "fatal: ••• bad")
    }

    /// A downloaded repo whose .git/config asks git to run a program on
    /// `git status` (core.fsmonitor) must not get to run it.
    @Test func repoConfigCannotRunCommands() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mapo-fsmon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await sh("git init -q -b main && echo 1 > a.ts && git add . && git commit -qm bir", dir)
        let marker = dir.appendingPathComponent("PWNED")
        let script = dir.appendingPathComponent("evil.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try await sh("git config core.fsmonitor '\(script.path)'", dir)
        _ = await GitInfo.recentlyChangedFiles(at: dir)
        _ = await GitInfo.head(at: dir)
        _ = await RepoSync.update(dir, token: nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
