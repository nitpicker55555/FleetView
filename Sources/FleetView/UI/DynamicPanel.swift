import SwiftUI
import WebKit

/// The region at the top of FleetView's content column (to the right of the sidebar) that renders
/// the agent-authored dynamic panel
/// (`~/.fleetview/ui/panel.html`, served at `/panel`). Shown only when a panel file exists; polls its
/// mtime and reloads the web view when the agent rewrites it. Collapsible. Read-only (v1).
struct DynamicPanel: View {
    @EnvironmentObject var state: AppState
    @State private var collapsed = false

    var body: some View {
        // `panelExists` / `panelMtime` are published by AppState's file watcher, so the panel shows up
        // (and reloads) the moment an agent writes the file — this view owns no timer of its own.
        Group {
            if state.panelExists, state.web.port > 0,
               let url = URL(string: "http://127.0.0.1:\(state.web.port)/panel") {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 10))
                            .foregroundColor(Theme.accent.opacity(0.8))
                        Text("AGENT PANEL").font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.subtext).tracking(0.5)
                        Spacer()
                        Button(collapsed ? "Show" : "Hide") {
                            withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() }
                        }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.accent)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.panel)
                    if !collapsed {
                        WebPanelView(url: url, reloadToken: state.panelMtime).frame(height: 240)
                    }
                    Divider().overlay(Theme.stroke)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.panelExists)
    }
}

/// A WKWebView that (re)loads `url` whenever `reloadToken` changes (the panel file's mtime).
private struct WebPanelView: NSViewRepresentable {
    let url: URL
    let reloadToken: TimeInterval

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.setValue(false, forKey: "drawsBackground")   // transparent to the panel's own background
        context.coordinator.load(wv, url, reloadToken)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.load(wv, url, reloadToken)   // no-op unless the token changed
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var lastToken: TimeInterval = -1
        func load(_ wv: WKWebView, _ url: URL, _ token: TimeInterval) {
            guard token != lastToken else { return }
            lastToken = token
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "t", value: String(Int(token)))]   // cache-bust
            wv.load(URLRequest(url: comps?.url ?? url))
        }
    }
}
