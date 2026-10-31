import AppKit
import WebKit

/// The web chat's share flow in a window of its own: dropping a card on 分享 opens that card's
/// conversation with the share sheet already up — the whole conversation or picked messages, the
/// same page a phone gets (`#share=<id>`).
///
/// Not a native copy of it. The shared page is rendered by the web's `md()`; a second renderer here
/// would make a share from the Mac read differently from one made on a phone, and drift from it
/// with every fix. What the window adds is what a bare WKWebView lacks: `confirm()` (withdrawing
/// asks first), `window.open` (the link opens in the browser), and downloads (the HTML lands in
/// Downloads).
@MainActor
final class ShareWindows: NSObject, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    static let shared = ShareWindows()

    private var windows: [UUID: NSWindow] = [:]
    private var saved: [ObjectIdentifier: URL] = [:]

    func open(terminal id: UUID, name: String, port: Int) {
        guard port > 0, let url = URL(string: "http://localhost:\(port)/#share=\(id.uuidString)") else {
            NSSound.beep()
            return
        }
        if let w = windows[id], let web = w.contentView as? WKWebView {
            // Again on an open window: put the sheet back up rather than stack a second window.
            web.load(URLRequest(url: URL(string: "about:blank")!))
            web.load(URLRequest(url: url))
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = self
        web.navigationDelegate = self
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 880),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = L(.shareWindowTitle(name))
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("FleetViewShareWindow")
        if !w.setFrameUsingName("FleetViewShareWindow") { w.center() }
        windows[id] = w
        web.load(URLRequest(url: url))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        (w.contentView as? WKWebView)?.stopLoading()
        windows = windows.filter { $0.value !== w }
    }

    // MARK: What a page expects from a browser

    /// The share result's "open": the public link belongs in the real browser, not in this window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L(.cancel))
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    /// "Download HTML" is a blob link with `download`: WebKit hands that over as a download, and
    /// without a delegate for it nothing happens at all.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FV.home
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var url = dir.appendingPathComponent(suggestedFilename)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        saved[ObjectIdentifier(download)] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = saved.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        saved.removeValue(forKey: ObjectIdentifier(download))
        NSSound.beep()
    }
}
