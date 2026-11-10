import SwiftUI
import WebKit

/// The PM's column at the board's right edge: the web dashboard's own conversation view of the PM
/// card, in dock mode (`/?dock=pm`).
///
/// Embedded rather than drawn natively for the reason PeerWebBoard gives: that view already exists —
/// the chat, images, send status, the prompt wheel, the terminal mirror — and the phone needs it
/// anyway, so the side questions and the PM's dropdown are written once, there, and the desktop and
/// the phone cannot drift apart.
struct PMDock: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var pm: PMCoordinator

    static let width: CGFloat = 400

    var body: some View {
        Group {
            if !PMCoordinator.enabled {
                note(L(.pmDockOff))
            } else if state.web.port > 0, let url = URL(string: "http://127.0.0.1:\(state.web.port)/?dock=pm") {
                PMWebView(url: url)
            } else {
                note(L(.pmDockNoServer))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
            .multilineTextAlignment(.center).padding(24)
    }
}

/// A WKWebView that loads its page once and then leaves it alone: the page navigates itself (its
/// hash follows the open conversation), and reloading on every SwiftUI update would throw away the
/// draft in its composer.
private struct PMWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKUIDelegate {
        var loaded: URL?

        /// The page asks with `prompt()` (adding a note) and `confirm()`; WebKit answers neither
        /// without a delegate, which reads as the button doing nothing.
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let alert = NSAlert()
            alert.messageText = prompt
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: L(.cancel))
            completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
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

        /// Links the conversation shows open in the browser, not in the column.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = navigationAction.request.url { NSWorkspace.shared.open(u) }
            return nil
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        load(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        load(view, context.coordinator)
    }

    private func load(_ view: WKWebView, _ c: Coordinator) {
        guard c.loaded != url else { return }
        c.loaded = url
        view.load(URLRequest(url: url))
    }
}
