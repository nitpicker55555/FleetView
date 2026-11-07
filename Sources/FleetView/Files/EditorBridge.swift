import AppKit
import SwiftUI
import WebKit

/// Where the editor page lives: bundled into the app by package_app.sh, or — for a binary run out of
/// `.build` — the checkout's `Editor/dist`. Searched the way PMRunner finds `project-manager`.
enum EditorResources {
    static let dir: URL? = {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("editor")) }
        if let repo = Bundle.main.infoDictionary?["FVSourceRepo"] as? String {
            candidates.append(URL(fileURLWithPath: repo).appendingPathComponent("Editor/dist"))
        }
        if var dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            for _ in 0..<6 {
                candidates.append(dir.appendingPathComponent("Editor/dist"))
                dir.deleteLastPathComponent()
            }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("editor.js").path) }
    }()

    private static var cache: [String: Data] = [:]
    @MainActor static func file(_ name: String) -> Data? {
        if let d = cache[name] { return d }
        guard let dir, ["index.html", "editor.js", "editor.css"].contains(name),
              let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        cache[name] = d
        return d
    }
}

/// What the page asks Swift for, answered by the window's model.
@MainActor
protocol EditorHost: AnyObject {
    func serve(_ kind: String, _ rest: String) async -> EditorBridge.Response
    func editorMessage(_ type: String, _ body: [String: Any]) async -> Any?
    func editorReady()
    func editorCrashed()
}

/// The window's one web view, and the two channels to it: the `fvfile:` scheme for content and a
/// message handler for everything else.
@MainActor
final class EditorBridge: NSObject, WKNavigationDelegate {
    struct Response {
        var status: Int
        var mime: String
        var data: Data
        var headers: [String: String] = [:]

        static func json(_ status: Int, _ obj: [String: Any]) -> Response {
            Response(status: status, mime: "application/json",
                     data: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
        }
        static let notFound = Response(status: 404, mime: "text/plain", data: Data())
    }

    let webView: WKWebView
    weak var host: EditorHost?
    static let defaultFontSize = 13
    private(set) var fontSize = defaultFontSize
    private(set) var ready = false
    private var pending: [() -> Void] = []
    private let scheme = SchemeHandler()
    private let proxy = MessageProxy()

    override init() {
        let config = WKWebViewConfiguration()
        // Nothing the page does is kept: no cache, cookies or storage on disk.
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(scheme, forURLScheme: "fvfile")
        config.userContentController.addScriptMessageHandler(proxy, contentWorld: .page, name: "fv")
        config.preferences.isElementFullscreenEnabled = false
        webView = WKWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = NSColor(Theme.surface)
        webView.allowsMagnification = true
        super.init()
        scheme.bridge = self
        proxy.bridge = self
        webView.navigationDelegate = self
        load()
    }

    func load() {
        ready = false
        webView.load(URLRequest(url: URL(string: "fvfile://app/index.html")!))
    }

    /// Everything the page holds is let go: called when the window closes.
    func tearDown() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
        webView.navigationDelegate = nil
        scheme.bridge = nil
        proxy.bridge = nil
        pending.removeAll()
    }

    /// Call `fv.<function>(…args)` once the page is up. `args` are passed as real arguments, never
    /// spliced into the source.
    func call(_ function: String, _ args: [Any] = [], done: ((Any?) -> Void)? = nil) {
        let run = { [weak self] in
            guard let self else { return }
            var named: [String: Any] = [:]
            var list: [String] = []
            for (i, a) in args.enumerated() { named["a\(i)"] = a; list.append("a\(i)") }
            let src = "return await fv.\(function)(\(list.joined(separator: ", ")))"
            self.webView.callAsyncJavaScript(src, arguments: named, in: nil, in: .page) { result in
                switch result {
                case .success(let v): done?(v)
                case .failure(let e):
                    FV.log("files: fv.\(function) failed: \(e.localizedDescription)")
                    done?(nil)
                }
            }
        }
        if ready { run() } else { pending.append(run) }
    }

    func callAsync(_ function: String, _ args: [Any] = []) async -> Any? {
        await withCheckedContinuation { c in call(function, args) { c.resume(returning: $0) } }
    }

    // MARK: theme

    func applyTheme() {
        let appearance = webView.effectiveAppearance
        // Re-set, not just set once in init: a new seed (ThemeStore) changes the surface too.
        webView.underPageBackgroundColor = NSColor(Theme.surface)
        call("setTheme", [Self.colors(for: appearance), fontSize])
    }

    func setFontSize(_ size: Int) {
        fontSize = min(28, max(9, size))
        applyTheme()
    }

    static func colors(for appearance: NSAppearance) -> [String: String] {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        func css(_ c: Color, _ alpha: Double = 1) -> String {
            var out = "#000000"
            appearance.performAsCurrentDrawingAppearance {
                guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
                let r = Int(round(ns.redComponent * 255)), g = Int(round(ns.greenComponent * 255))
                let b = Int(round(ns.blueComponent * 255))
                out = alpha >= 1 ? String(format: "#%02x%02x%02x", r, g, b)
                                 : "rgba(\(r),\(g),\(b),\(String(format: "%.3f", alpha)))"
            }
            return out
        }
        // Syntax colours: the dark ones are the web mockups'; the light ones the same roles taken from
        // the light scheme, dark enough to read on white. Keywords, functions and attributes are
        // scheme roles (primary, on-primary-container, tertiary) and follow the seed; strings,
        // numbers, types and properties are fixed hues so code stays readable whatever the seed is.
        let syntax: [String: String] = dark
            ? ["hk": css(Theme.primary), "hs": "#e6c68f", "hc": "#8a8492", "hn": "#ffb86a", "ht": "#8ecfff",
               "hf": css(Theme.onPrimaryContainer), "ha": css(Theme.tertiary), "hp": "#b8d7ff"]
            : ["hk": css(Theme.primary), "hs": "#8a5a00", "hc": "#7a757f", "hn": "#a04b00", "ht": "#00658a",
               "hf": css(Theme.onPrimaryContainer), "ha": css(Theme.tertiary), "hp": "#1d5c8a"]
        var c: [String: String] = [
            "bg": css(Theme.surface), "panel": css(Theme.surfaceContainerLow), "high": css(Theme.surfaceContainerHigh),
            "stroke": css(Theme.outlineVariant), "text": css(Theme.onSurface), "sub": css(Theme.onSurfaceVariant),
            "outline": css(Theme.outline), "gutter": css(Theme.outline, 0.75), "accent": css(Theme.primary),
            "onAccent": css(Theme.onPrimary), "sel": css(Theme.primary, dark ? 0.24 : 0.20),
            "selMatch": css(Theme.primary, 0.12), "activeLine": css(Theme.onSurface, dark ? 0.035 : 0.04),
            "match": css(Theme.warn, 0.30), "matchCur": css(Theme.warn), "onMatchCur": css(Theme.onWarnContainer),
            "tint": css(Theme.primary, dark ? 0.13 : 0.11), "tintAdd": css(Theme.primary, dark ? 0.18 : 0.15),
            "tintStrong": css(Theme.primary, 0.40), "del": css(Theme.error), "err": css(Theme.error),
            "scheme": dark ? "dark" : "light",
        ]
        c.merge(syntax) { a, _ in a }
        return c
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // The page itself and nothing else. Links in a document go to Swift as messages.
        let ok = action.request.url?.absoluteString == "fvfile://app/index.html"
        decisionHandler(ok ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        FV.log("files: editor page's web content process ended; reloading")
        ready = false
        load()
        host?.editorCrashed()
    }

    // MARK: messages

    fileprivate func receive(_ body: Any, reply: @escaping (Any?, String?) -> Void) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { reply(nil, nil); return }
        if type == "ready" {
            ready = true
            // Before anything queued: the page's own words (outline, search panel) and colours.
            call("init", [["lang": Lang.current == .zh ? "zh" : "en",
                           "colors": Self.colors(for: webView.effectiveAppearance), "fontSize": fontSize] as [String: Any]])
            let queued = pending
            pending.removeAll()
            queued.forEach { $0() }
            host?.editorReady()
            reply(nil, nil)
            return
        }
        Task { @MainActor in
            let answer = await self.host?.editorMessage(type, dict)
            reply(answer, nil)
        }
    }

    fileprivate func serve(_ url: URL) async -> Response {
        guard url.host == "app" else { return .notFound }
        var parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return .notFound }
        parts.removeFirst()
        switch first {
        case "index.html", "editor.js", "editor.css":
            guard let d = EditorResources.file(first) else {
                return Response(status: 404, mime: "text/html",
                                data: Data("<p style='font:13px -apple-system;color:#888;padding:20px'>\(L(.filesNoEditor))</p>".utf8))
            }
            let mime = first.hasSuffix(".js") ? "text/javascript" : first.hasSuffix(".css") ? "text/css" : "text/html"
            return Response(status: 200, mime: mime + "; charset=utf-8", data: d)
        default:
            guard let host else { return .notFound }
            let rest = first == "raw" ? "/" + parts.joined(separator: "/") : parts.joined(separator: "/")
            return await host.serve(first, rest)
        }
    }

    /// The scheme handler, kept apart so the configuration's strong reference to it does not keep the
    /// bridge (and through it the window) alive.
    private final class SchemeHandler: NSObject, WKURLSchemeHandler {
        weak var bridge: EditorBridge?
        /// Tasks WebKit has not stopped. Answering a stopped one raises an exception.
        private var live = Set<ObjectIdentifier>()

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let id = ObjectIdentifier(task)
            live.insert(id)
            guard let url = task.request.url else { finish(task, .notFound); return }
            Task { @MainActor in
                let r = await self.bridge?.serve(url) ?? .notFound
                self.finish(task, r)
            }
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
            live.remove(ObjectIdentifier(task))
        }

        private func finish(_ task: WKURLSchemeTask, _ r: Response) {
            let id = ObjectIdentifier(task)
            guard live.contains(id), let url = task.request.url else { return }
            live.remove(id)
            var headers = r.headers
            headers["Content-Type"] = r.mime
            headers["Content-Length"] = String(r.data.count)
            headers["Cache-Control"] = "no-store"
            let response = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            task.didReceive(response)
            task.didReceive(r.data)
            task.didFinish()
        }
    }

    /// Held strongly by the user content controller; holds the bridge weakly, or the controller would
    /// keep the window and its web content process alive after closing.
    private final class MessageProxy: NSObject, WKScriptMessageHandlerWithReply {
        weak var bridge: EditorBridge?

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard let bridge else { replyHandler(nil, nil); return }
            bridge.receive(message.body) { v, e in replyHandler(v, e) }
        }
    }
}

/// The web view in SwiftUI. The same instance every time: the page and every tab's editor state live
/// in it, so it must never be rebuilt by a SwiftUI update.
struct EditorHostView: NSViewRepresentable {
    let bridge: EditorBridge

    func makeNSView(context: Context) -> WKWebView { bridge.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
