import Foundation

/// One-time move from the app's former name (Atlas, until October 2026) to
/// Mapo, so early users keep their projects, maps, settings and GitHub sign-in.
///
/// Every step is idempotent and never destroys data it could not copy.
public enum LegacyMigration {
    public static let legacyName = "Atlas"
    public static let legacyBundleID = "io.github.bur2ak.atlas"
    /// MCP server name agents were configured with.
    public static let legacyServerName = "atlas"

    /// `~/Library/Application Support/Atlas` → `…/Mapo` when Mapo has no data yet.
    @discardableResult
    public static func moveDataFolder(to paths: MapoPaths, fileManager fm: FileManager = .default) -> Bool {
        let legacy = paths.base.deletingLastPathComponent().appendingPathComponent(legacyName, isDirectory: true)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: paths.libraryFile.path) else { return false }
        do {
            if fm.fileExists(atPath: paths.base.path) {
                // An empty Mapo folder (e.g. created by a first launch) is in the way.
                guard ((try? fm.contentsOfDirectory(atPath: paths.base.path)) ?? []).isEmpty else { return false }
                try fm.removeItem(at: paths.base)
            }
            try fm.moveItem(at: legacy, to: paths.base)
            rewriteLibraryPaths(from: legacy.path, to: paths.base.path, library: paths.libraryFile)
            return true
        } catch {
            return false
        }
    }

    /// Projects cloned from GitHub live under the data folder
    /// (`…/Atlas/Repos/owner/repo`): point them at the moved location.
    static func rewriteLibraryPaths(from old: String, to new: String, library: URL) {
        guard let data = try? Data(contentsOf: library),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var projects = root["projects"] as? [[String: Any]] else { return }
        var changed = false
        for i in projects.indices {
            if let p = projects[i]["rootPath"] as? String, p == old || p.hasPrefix(old + "/") {
                projects[i]["rootPath"] = new + p.dropFirst(old.count)
                changed = true
            }
        }
        guard changed else { return }
        root["projects"] = projects
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? out.write(to: library, options: .atomic)
        }
    }

    /// Copies preferences the old bundle id stored, without overwriting.
    public static func copyDefaults(keys: [String], into defaults: UserDefaults = .standard) {
        guard let old = UserDefaults(suiteName: legacyBundleID) else { return }
        for key in keys where defaults.object(forKey: key) == nil {
            if let v = old.object(forKey: key) { defaults.set(v, forKey: key) }
        }
    }

    /// Moves a keychain item from the old service name to the new one.
    public static func moveKeychainItem(account: String, to keychain: Keychain) {
        // Only when the new item is known to be absent: a read error must
        // not let an old token replace a newer one.
        guard case .some(.none) = try? keychain.get(account: account) else { return }
        let old = Keychain(service: legacyBundleID)
        guard let data = try? old.get(account: account) else { return }
        do {
            try keychain.set(data, account: account)
            try? old.delete(account: account)
        } catch {}
    }
}
