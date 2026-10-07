import Foundation

/// GitHub sign-in (OAuth Device Flow) and the few API calls Mapo needs.
///
/// No client secret anywhere: device flow is designed for apps that cannot
/// keep one. The client id is public by nature.
public enum GitHub {
    public static let clientID = "Ov23ligebFbA7NFdB2o9"
    /// `repo` to list and clone private repositories, `read:org` to see
    /// organisation repositories.
    public static let scope = "repo read:org"

    // MARK: - Models

    public struct DeviceCode: Sendable, Equatable {
        public let deviceCode: String
        /// What the user types at `verificationURL`, e.g. `CA2E-FC10`.
        public let userCode: String
        public let verificationURL: URL
        public let expiresAt: Date
        public let interval: TimeInterval
    }

    public struct Token: Codable, Sendable, Equatable {
        public var accessToken: String
        public var expiresAt: Date?
        public var refreshToken: String?
        public var refreshExpiresAt: Date?

        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    public struct User: Codable, Sendable, Equatable {
        public let login: String
        public let name: String?
        public let avatarURL: URL?

        public init(login: String, name: String?, avatarURL: URL?) {
            self.login = login
            self.name = name
            self.avatarURL = avatarURL
        }

        enum CodingKeys: String, CodingKey {
            case login, name
            case avatarURL = "avatar_url"
        }
    }

    public struct Repository: Codable, Sendable, Hashable, Identifiable {
        public let id: Int
        public let fullName: String
        public let name: String
        public let owner: String
        public let isPrivate: Bool
        public let description: String?
        public let language: String?
        public let defaultBranch: String
        public let pushedAt: Date?
        public let cloneURL: URL
        public let isArchived: Bool
        public let isFork: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, description, language, owner, fork, archived
            case fullName = "full_name"
            case isPrivate = "private"
            case defaultBranch = "default_branch"
            case pushedAt = "pushed_at"
            case cloneURL = "clone_url"
        }

        struct Owner: Codable { let login: String }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            fullName = try c.decode(String.self, forKey: .fullName)
            name = try c.decode(String.self, forKey: .name)
            owner = try c.decode(Owner.self, forKey: .owner).login
            isPrivate = try c.decode(Bool.self, forKey: .isPrivate)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            language = try c.decodeIfPresent(String.self, forKey: .language)
            defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch) ?? "main"
            pushedAt = try c.decodeIfPresent(Date.self, forKey: .pushedAt)
            cloneURL = try c.decode(URL.self, forKey: .cloneURL)
            isArchived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
            isFork = try c.decodeIfPresent(Bool.self, forKey: .fork) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(fullName, forKey: .fullName)
            try c.encode(name, forKey: .name)
            try c.encode(Owner(login: owner), forKey: .owner)
            try c.encode(isPrivate, forKey: .isPrivate)
            try c.encodeIfPresent(description, forKey: .description)
            try c.encodeIfPresent(language, forKey: .language)
            try c.encode(defaultBranch, forKey: .defaultBranch)
            try c.encodeIfPresent(pushedAt, forKey: .pushedAt)
            try c.encode(cloneURL, forKey: .cloneURL)
            try c.encode(isArchived, forKey: .archived)
            try c.encode(isFork, forKey: .fork)
        }
    }

    public enum AuthError: Error, LocalizedError, Equatable {
        case expired
        case denied
        case network(String)
        case unexpected(String)

        public var errorDescription: String? {
            switch self {
            case .expired: String(localized: "Kodun süresi doldu. Yeniden dene.")
            case .denied: String(localized: "GitHub'da izin verilmedi.")
            case .network(let m): String(localized: "GitHub'a ulaşılamadı: \(m)")
            case .unexpected(let m): String(localized: "GitHub beklenmeyen bir yanıt verdi: \(m)")
            }
        }
    }

    public enum APIError: Error, LocalizedError, Equatable {
        case unauthorized
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .unauthorized: String(localized: "GitHub oturumunun süresi doldu. Yeniden bağlan.")
            case .http(let code): String(localized: "GitHub isteği başarısız oldu (HTTP \(code)).")
            }
        }
    }
}

// MARK: - Device flow

public struct GitHubAuth: Sendable {
    let session: URLSession
    let clientID: String
    /// Injectable for tests (polling must not really wait 5 s).
    let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(session: URLSession = .shared, clientID: String = GitHub.clientID,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.session = session
        self.clientID = clientID
        self.sleep = sleep
    }

    public func requestCode() async throws -> GitHub.DeviceCode {
        let json = try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": GitHub.scope])
        guard let device = json["device_code"] as? String,
              let user = json["user_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:))
        else { throw GitHub.AuthError.unexpected(Self.describe(json)) }
        return GitHub.DeviceCode(
            deviceCode: device,
            userCode: user,
            verificationURL: uri,
            expiresAt: Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 900),
            interval: json["interval"] as? TimeInterval ?? 5
        )
    }

    /// Polls until the user approves, declines, or the code expires.
    public func waitForToken(_ code: GitHub.DeviceCode) async throws -> GitHub.Token {
        var interval = max(1, code.interval)
        while true {
            try await sleep(interval)
            try Task.checkCancellation()
            if Date() > code.expiresAt { throw GitHub.AuthError.expired }
            let json = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = Self.token(from: json) { return token }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval = (json["interval"] as? TimeInterval) ?? interval + 5
            case "expired_token": throw GitHub.AuthError.expired
            case "access_denied": throw GitHub.AuthError.denied
            default: throw GitHub.AuthError.unexpected(Self.describe(json))
            }
        }
    }

    /// Exchanges a refresh token. Returns nil when GitHub refuses (the
    /// caller signs out and asks the user to connect again).
    public func refresh(_ token: GitHub.Token) async throws -> GitHub.Token? {
        guard let refresh = token.refreshToken else { return nil }
        if let exp = token.refreshExpiresAt, exp < Date() { return nil }
        let json = try await post("https://github.com/login/oauth/access_token", [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ])
        return Self.token(from: json)
    }

    static func token(from json: [String: Any]) -> GitHub.Token? {
        guard let access = json["access_token"] as? String, !access.isEmpty else { return nil }
        let now = Date()
        return GitHub.Token(
            accessToken: access,
            expiresAt: (json["expires_in"] as? TimeInterval).map { now.addingTimeInterval($0) },
            refreshToken: json["refresh_token"] as? String,
            refreshExpiresAt: (json["refresh_token_expires_in"] as? TimeInterval).map { now.addingTimeInterval($0) }
        )
    }

    private func post(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: Self.formSafe) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let data: Data
        do {
            (data, _) = try await session.data(for: req)
        } catch {
            throw GitHub.AuthError.network(error.localizedDescription)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHub.AuthError.unexpected(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return json
    }

    /// RFC 3986 unreserved characters: everything else is percent-encoded.
    static let formSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    /// Never echoes tokens back into error messages.
    static func describe(_ json: [String: Any]) -> String {
        if let e = json["error_description"] as? String { return e }
        if let e = json["error"] as? String { return e }
        return json.keys.sorted().joined(separator: ", ")
    }
}

// MARK: - REST API

public struct GitHubAPI: Sendable {
    let session: URLSession
    let token: String

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    public func user() async throws -> GitHub.User {
        let (data, _) = try await get(URL(string: "https://api.github.com/user")!)
        return try JSONDecoder().decode(GitHub.User.self, from: data)
    }

    /// Every repository the user can read (own, collaborator, organisation),
    /// most recently pushed first. Follows pagination.
    public func repositories(maxPages: Int = 10) async throws -> [GitHub.Repository] {
        var url: URL? = URL(string: "https://api.github.com/user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member")
        var all: [GitHub.Repository] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var pages = 0
        while let next = url, pages < maxPages {
            let (data, response) = try await get(next)
            all += try decoder.decode([GitHub.Repository].self, from: data)
            url = Self.nextPage(response.value(forHTTPHeaderField: "Link"))
            pages += 1
        }
        return all.sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
    }

    /// `<https://…?page=2>; rel="next", <…>; rel="last"` → page 2 URL.
    static func nextPage(_ link: String?) -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces[1] == "rel=\"next\"" else { continue }
            let raw = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: raw)
        }
        return nil
    }

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Mapo", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GitHub.APIError.http(0) }
        if http.statusCode == 401 { throw GitHub.APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw GitHub.APIError.http(http.statusCode) }
        return (data, http)
    }
}
