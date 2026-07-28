import SwiftUI
import WebKit

/// The region at the top of FleetView's content column (to the right of the sidebar) that renders
/// the agent-authored dynamic panel
/// (`~/.fleetview/ui/panel.html`, served at `/panel`). Shown only when a panel file exists; polls its
/// mtime and reloads the web view when the agent rewrites it. Collapsible. Read-only (v1).
struct DynamicPanel: View {
    @EnvironmentObject var state: AppState
    @State private var collapsed = false
    /// A version pinned from the history menu; `nil` means "follow the newest".
    @State private var pinned: PanelVersions.Summary?
    @State private var history: [PanelVersions.Summary] = []

    var body: some View {
        // `panelExists` / `panelVersion` are published by AppState's file watcher, so the panel shows
        // up (and reloads) the moment an agent writes the file — this view owns no timer of its own.
        Group {
            if state.panelExists, state.web.port > 0, let url = panelURL {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 10))
                            .foregroundColor(Theme.accent.opacity(0.8))
                        Text("AGENT PANEL").font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.subtext).tracking(0.5)
                        if let pinned {
                            Text("· \(pinned.label)").font(.system(size: 10))
                                .foregroundColor(Theme.subtext).lineLimit(1)
                        }
                        Spacer()
                        historyMenu
                        Button(collapsed ? "Show" : "Hide") {
                            withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() }
                        }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.accent)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.panel)
                    if !collapsed {
                        // Keyed on the version uuid, not on mtime: touching the file no longer
                        // reflows the panel for nothing.
                        WebPanelView(url: url, reloadToken: pinned?.uuid ?? state.panelVersion)
                            .frame(height: 240)
                    }
                    Divider().overlay(Theme.stroke)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.panelExists)
    }

    /// Every version an agent ever wrote is kept, so the menu is a real history, not a cache.
    private var historyMenu: some View {
        Menu {
            Button("Live (newest)") { pinned = nil }
            if !history.isEmpty { Divider() }
            ForEach(history) { version in
                Button(version.label) { pinned = version }
            }
        } label: {
            Text("History").font(.system(size: 11, weight: .medium)).foregroundColor(Theme.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear { history = PanelVersions.shared.recentSummaries() }
        .onChange(of: state.panelVersion) { _ in history = PanelVersions.shared.recentSummaries() }
    }

    private var panelURL: URL? {
        var path = "http://127.0.0.1:\(state.web.port)/panel"
        if let pinned { path += "?v=\(pinned.uuid)" }
        return URL(string: path)
    }
}

/// A WKWebView that (re)loads `url` whenever `reloadToken` changes (the archived version's uuid).
private struct WebPanelView: NSViewRepresentable {
    let url: URL
    let reloadToken: String

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
        private var lastToken: String?
        func load(_ wv: WKWebView, _ url: URL, _ token: String) {
            guard token != lastToken else { return }
            lastToken = token
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = comps?.queryItems ?? []
            items.append(URLQueryItem(name: "t", value: token.isEmpty ? "0" : token))   // cache-bust
            comps?.queryItems = items
            wv.load(URLRequest(url: comps?.url ?? url))
        }
    }
}
