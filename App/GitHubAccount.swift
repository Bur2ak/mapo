import AppKit
import AtlasCore
import Foundation
import Observation
import os

private let log = Logger(subsystem: "io.github.bur2ak.atlas", category: "github")

/// The signed-in GitHub account. The token lives only in the keychain.
@MainActor
@Observable
final class GitHubAccount {
    enum State: Equatable {
        case signedOut
        /// Waiting for the user to enter `code.userCode` on GitHub.
        case signingIn(GitHub.DeviceCode)
        case signedIn(GitHub.User)
    }

    private(set) var state: State = .signedOut
    private(set) var signInError: String?
    private(set) var repositories: [GitHub.Repository] = []
    private(set) var isLoadingRepositories = false
    private(set) var repositoriesError: String?

    private let keychain = Keychain(service: "io.github.bur2ak.atlas")
    private let account = "github"
    private let auth = GitHubAuth()
    @ObservationIgnored private var signInTask: Task<Void, Never>?

    var user: GitHub.User? {
        if case .signedIn(let u) = state { return u }
        return nil
    }

    /// Restores a saved session (no network if the token is still fresh).
    func restore() async {
        guard let token = await storedToken() else { log.info("restore: no stored token"); return }
        log.info("restore: token found, expired=\(token.isExpired, privacy: .public)")
        do {
            let fresh = try await ensureFresh(token)
            let user = try await GitHubAPI(token: fresh.accessToken).user()
            log.info("restore: signed in as \(user.login, privacy: .public)")
            UserDefaults.standard.set(user.login, forKey: "githubLogin")
            state = .signedIn(user)
        } catch GitHub.APIError.unauthorized {
            log.error("restore: unauthorized, signing out")
            signOut()
        } catch {
            log.error("restore failed: \(String(describing: error), privacy: .public)")
            // Offline at launch: keep the session, try again when needed.
            if let login = UserDefaults.standard.string(forKey: "githubLogin") {
                state = .signedIn(GitHub.User(login: login, name: nil, avatarURL: nil))
            }
        }
    }

    func signIn() {
        signInTask?.cancel()
        signInError = nil
        signInTask = Task {
            do {
                let code = try await auth.requestCode()
                state = .signingIn(code)
                log.info("signIn: code issued, polling")
                let token = try await auth.waitForToken(code)
                log.info("signIn: token received, expires=\(token.expiresAt != nil, privacy: .public)")
                try await save(token)
                let user = try await GitHubAPI(token: token.accessToken).user()
                log.info("signIn: user \(user.login, privacy: .public)")
                UserDefaults.standard.set(user.login, forKey: "githubLogin")
                state = .signedIn(user)
                await loadRepositories()
            } catch is CancellationError {
                state = .signedOut
            } catch {
                log.error("signIn failed: \(String(describing: error), privacy: .public)")
                state = .signedOut
                signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        state = .signedOut
    }

    func signOut() {
        signInTask?.cancel()
        let (k, a) = (keychain, account)
        Task.detached { try? k.delete(account: a) }
        UserDefaults.standard.removeObject(forKey: "githubLogin")
        repositories = []
        state = .signedOut
    }

    /// Copies the code and opens GitHub's device page.
    func openVerificationPage(_ code: GitHub.DeviceCode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.userCode, forType: .string)
        NSWorkspace.shared.open(code.verificationURL)
    }

    func loadRepositories() async {
        guard user != nil else { return }
        isLoadingRepositories = true
        repositoriesError = nil
        defer { isLoadingRepositories = false }
        do {
            guard let token = try await accessToken() else { return }
            repositories = try await GitHubAPI(token: token).repositories()
        } catch GitHub.APIError.unauthorized {
            signOut()
            signInError = GitHub.APIError.unauthorized.errorDescription
        } catch {
            repositoriesError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A valid access token, refreshed when needed; nil when signed out.
    func accessToken() async throws -> String? {
        guard let token = await storedToken() else { return nil }
        return try await ensureFresh(token).accessToken
    }

    // MARK: - Storage

    // Keychain calls run off the main actor: macOS may show an access
    // prompt, and the UI must never freeze behind it.

    private func storedToken() async -> GitHub.Token? {
        let (k, a) = (keychain, account)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? k.get(account: a) else { return nil }
            return try? JSONDecoder().decode(GitHub.Token.self, from: data)
        }.value
    }

    private func save(_ token: GitHub.Token) async throws {
        let (k, a) = (keychain, account)
        let data = try JSONEncoder().encode(token)
        try await Task.detached(priority: .userInitiated) { try k.set(data, account: a) }.value
    }

    private func ensureFresh(_ token: GitHub.Token) async throws -> GitHub.Token {
        guard token.isExpired else { return token }
        guard let fresh = try await auth.refresh(token) else { throw GitHub.APIError.unauthorized }
        try await save(fresh)
        return fresh
    }
}
