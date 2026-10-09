import AppKit

/// Help › Send Feedback…: a GitHub issue pre-filled with what helps triage
/// (version, macOS). Nothing is sent until the user submits it there.
enum Feedback {
    static let repository = "https://github.com/Bur2ak/mapo"

    static func open() {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let body = """
        **Ne oldu? / What happened?**


        **Ne bekliyordun? / What did you expect?**


        ---
        Mapo \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        """
        var c = URLComponents(string: repository + "/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}
