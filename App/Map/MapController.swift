import AppKit
import Observation
import SwiftUI
import WebKit

/// Owns the map web view and the Swift ⇄ JS bridge (Map/src/main.ts `mapoMap`).
///
/// Commands issued before the page reports `ready` are queued, so callers
/// never have to care about load timing.
@MainActor
@Observable
final class MapController: NSObject {
    enum Event {
        case loaded(nodes: Int, edges: Int)
        case select(String?)
        case open(String)
        case layoutProgress(Double)
        case layout([String: [Double]])
        case error(String)
    }

    enum Detail: Int, CaseIterable, Identifiable {
        case files = 0, symbols = 1, everything = 2
        var id: Int { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .files: "Dosyalar"
            case .symbols: "Kod"
            case .everything: "Tümü"
            }
        }
    }

    enum ColorMode: String, CaseIterable, Identifiable {
        case folder, community
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .community: "Kümeye göre"
            case .folder: "Klasöre göre"
            }
        }
    }

    /// One coloured area of the map, for the legend.
    struct Group: Identifiable, Equatable {
        /// -1 = everything too small to get its own colour.
        let id: Int
        let name: String
        let color: Color
        let count: Int
    }

    private(set) var isReady = false
    private(set) var groups: [Group] = []
    private(set) var groupsMode: ColorMode = .folder
    /// 0…1 while the force layout runs, nil otherwise.
    private(set) var layoutProgress: Double?

    var detail: Detail = .files {
        didSet { if !syncingFromMap { call("mapoMap.setDetail(v)", ["v": detail.rawValue]) } }
    }
    @ObservationIgnored private var syncingFromMap = false
    var colorMode: ColorMode = .folder { didSet { call("mapoMap.setColorMode(v)", ["v": colorMode.rawValue]) } }
    var hideTests = false { didSet { call("mapoMap.setHideTests(v)", ["v": hideTests]) } }
    /// Build output, bundles and tool config (hidden by default).
    var showNoise = false {
        didSet { if !syncingFromMap { call("mapoMap.setShowNoise(v)", ["v": showNoise]) } }
    }

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    @ObservationIgnored private(set) var webView: WKWebView!
    @ObservationIgnored private var queue: [(String, [String: Any])] = []
    /// Reloaded automatically if the web content process restarts.
    @ObservationIgnored private var loadedProject: UUID?
    @ObservationIgnored private let schemeHandler: MapoSchemeHandler

    init(payloadProvider: @escaping @MainActor (String) -> Data?) {
        schemeHandler = MapoSchemeHandler(payloadProvider: payloadProvider)
        super.init()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: MapoSchemeHandler.scheme)
        config.userContentController.add(WeakMessageHandler(self), name: "mapo")
        config.suppressesIncrementalRendering = true

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        #if DEBUG
        view.isInspectable = true
        #endif
        webView = view
        view.load(URLRequest(url: URL(string: "\(MapoSchemeHandler.scheme)://app/index.html")!))
    }

    // MARK: Commands

    /// `keepView`: a refresh of the same project keeps camera, detail and
    /// selection instead of re-framing the whole map.
    func load(projectID: UUID, keepView: Bool = false, select: String? = nil) {
        loadedProject = projectID
        var args: [String: Any] = ["url": MapoSchemeHandler.payloadURL(projectID), "keep": keepView]
        args["sel"] = select ?? NSNull()
        call("mapoMap.load(url, keep, sel)", args)
    }

    func select(_ id: String?) {
        if let id { call("mapoMap.select(id)", ["id": id]) } else { call("mapoMap.select(null)", [:]) }
    }

    func focus(_ id: String) { call("mapoMap.focus(id)", ["id": id]) }
    func showPath(_ nodeIDs: [String]) { call("mapoMap.showPath(ids)", ["ids": nodeIDs]) }
    func highlight(_ nodeIDs: [String]) { call("mapoMap.highlightSet(ids)", ["ids": nodeIDs]) }
    func clearHighlight() { call("mapoMap.clearHighlight()", [:]) }
    func fit() { call("mapoMap.fit()", [:]) }
    func focusGroup(_ id: Int) { call("mapoMap.focusGroup(g)", ["g": id]) }
    func zoom(_ factor: Double) { call("mapoMap.zoom(f)", ["f": factor]) }
    func relayout() { call("mapoMap.relayout()", [:]) }

    private func call(_ body: String, _ args: [String: Any]) {
        guard isReady else {
            // Keep only the latest of each command kind; `load` always survives.
            let key = body.prefix { $0 != "(" }
            queue.removeAll { $0.0.prefix { $0 != "(" } == key }
            queue.append((body, args))
            return
        }
        webView.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NSLog("Mapo map call failed: \(body): \(error)")
            }
        }
    }

    // MARK: Messages

    fileprivate func receive(_ body: Any) {
        #if DEBUG
        if let m = body as? [String: Any], m["type"] as? String != "layoutProgress" {
            NSLog("[mapo-js] %@", String(describing: m["type"] ?? "?") + " " + String(describing: m["message"] ?? m["id"] ?? m["nodes"] ?? ""))
        }
        #endif
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            var pending = queue
            queue.removeAll()
            if let id = loadedProject, !pending.contains(where: { $0.0.hasPrefix("mapoMap.load(") }) {
                pending.insert(("mapoMap.load(url, keep, sel)", ["url": MapoSchemeHandler.payloadURL(id), "keep": false, "sel": NSNull()]), at: 0)
            }
            // Re-apply view options, then queued commands in order.
            call("mapoMap.setDetail(v)", ["v": detail.rawValue])
            call("mapoMap.setColorMode(v)", ["v": colorMode.rawValue])
            call("mapoMap.setHideTests(v)", ["v": hideTests])
            call("mapoMap.setShowNoise(v)", ["v": showNoise])
            pending.forEach { call($0.0, $0.1) }
        case "loaded":
            onEvent?(.loaded(nodes: msg["nodes"] as? Int ?? 0, edges: msg["edges"] as? Int ?? 0))
        case "select":
            onEvent?(.select(msg["id"] as? String))
        case "open":
            if let id = msg["id"] as? String { onEvent?(.open(id)) }
        case "layoutProgress":
            let v = msg["value"] as? Double ?? 0
            layoutProgress = v >= 1 ? nil : v
            onEvent?(.layoutProgress(v))
        case "layout":
            layoutProgress = nil
            guard let raw = msg["positions"] as? [String: [Any]] else { return }
            var positions: [String: [Double]] = [:]
            positions.reserveCapacity(raw.count)
            for (id, xy) in raw {
                let v = xy.compactMap { ($0 as? NSNumber)?.doubleValue }
                if v.count == 2 { positions[id] = v }
            }
            onEvent?(.layout(positions))
        case "detail":
            // The map raised its own detail (e.g. to reveal a searched symbol).
            if let raw = msg["value"] as? Int, let d = Detail(rawValue: raw) {
                syncingFromMap = true
                detail = d
                syncingFromMap = false
            }
        case "noise":
            if let v = msg["value"] as? Bool {
                syncingFromMap = true
                showNoise = v
                syncingFromMap = false
            }
        case "groups":
            groupsMode = (msg["mode"] as? String).flatMap(ColorMode.init(rawValue:)) ?? .folder
            groups = (msg["groups"] as? [[String: Any]] ?? []).compactMap { g in
                guard let id = g["id"] as? Int, let hex = g["color"] as? String else { return nil }
                return Group(id: id, name: g["name"] as? String ?? "", color: Color(hex: hex), count: g["count"] as? Int ?? 0)
            }
        case "error":
            onEvent?(.error(msg["message"] as? String ?? "?"))
        default:
            break
        }
    }
}

extension MapController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The map never navigates anywhere except its own bundled page.
        action.request.url?.scheme == MapoSchemeHandler.scheme ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page lost its state; reloading re-sends `ready`, which
        // re-issues the last project load.
        isReady = false
        webView.reload()
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: MapController?
    init(_ target: MapController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.receive(message.body) }
    }
}

/// Serves `mapo://app/<file>` from the bundled map and
/// `mapo://app/project/<uuid>/map.json` from the open workspace.
final class MapoSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mapo"

    static func payloadURL(_ id: UUID) -> String {
        "\(scheme)://app/project/\(id.uuidString)/map.json"
    }
    private let payloadProvider: @MainActor (String) -> Data?

    init(payloadProvider: @escaping @MainActor (String) -> Data?) {
        self.payloadProvider = payloadProvider
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        MainActor.assumeIsolated {
            guard let url = task.request.url, let host = url.host() else {
                return fail(task, 400)
            }
            #if DEBUG
            NSLog("[mapo-scheme] %@", url.absoluteString)
            #endif
            // Single origin (mapo://app) so the page's fetch is same-origin.
            guard host == "app" else { return fail(task, 404) }
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count == 3, parts[0] == "project", parts[2] == "map.json" {
                guard let data = payloadProvider(parts[1]) else { return fail(task, 404) }
                return respond(task, url: url, data: data, mime: "application/json")
            }
            guard parts.count == 1, let name = parts.first, !name.contains(".."),
                  let file = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Map"),
                  let data = try? Data(contentsOf: file)
            else { return fail(task, 404) }
            respond(task, url: url, data: data, mime: Self.mime(for: name))
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, mime: String) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-store",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask, _ status: Int) {
        let response = HTTPURLResponse(url: task.request.url ?? URL(string: "mapo://x")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        task.didReceive(response)
        task.didFinish()
    }

    static func mime(for name: String) -> String {
        switch (name as NSString).pathExtension {
        case "html": "text/html; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }
}

/// Hosts the controller's web view in SwiftUI.
struct MapView: NSViewRepresentable {
    let controller: MapController

    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

extension Color {
    /// "#RRGGBB" from the map's palette.
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(nsColor: NSColor(hex: v))
    }
}
