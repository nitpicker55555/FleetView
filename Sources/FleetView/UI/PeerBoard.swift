import SwiftUI
import WebKit

/// A peer's own web dashboard, embedded.
///
/// Nothing here re-implements the remote board: that page already exists, is served by the machine
/// it belongs to, and is the same UI a phone gets — cards, terminal view, the prompt bar, and the
/// Notes list as quick-command chips. Mirroring `/state` into native cards instead would mean a
/// second renderer to keep in step with this one, for a view you look at rather than work in.
struct PeerWebBoard: NSViewRepresentable {
    let peer: Peer

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: String?
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Each peer gets the shared store, so a session cookie set by one machine's dashboard
        // survives switching away and back.
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")   // let Theme.bg show through while loading
        load(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        load(view, context.coordinator)
    }

    /// Keyed on the peer, not on `view.url`: once the page navigates internally (opening a terminal
    /// pushes its own URL) `view.url` no longer equals what we asked for, and comparing the two
    /// would reload the dashboard out from under whatever you had opened.
    private func load(_ view: WKWebView, _ coordinator: Coordinator) {
        let target = peer.url + "/"
        guard coordinator.loaded != target, let url = URL(string: target) else { return }
        coordinator.loaded = target
        view.load(URLRequest(url: url))
    }
}

/// The switcher under the top bar: this machine, then every FleetView found on the LAN.
struct PeerStrip: View {
    @EnvironmentObject var state: AppState
    /// Observed explicitly: discovery publishes from its own object, and a view watching only
    /// AppState would sit on an empty list while the scan filled it in.
    @ObservedObject var fleet: PeerFleet

    private var others: [Peer] { fleet.found.filter { !$0.isSelf } }

    var body: some View {
        HStack(spacing: 6) {
            tab(title: "This Mac", detail: nil, active: state.peerSelected == nil) {
                state.peerSelected = nil
            }
            ForEach(others) { p in
                tab(title: p.label,
                    detail: p.working > 0 ? "\(p.terminals) · \(p.working) running"
                                          : "\(p.terminals) terminals",
                    active: state.peerSelected?.id == p.id) {
                    state.peerSelected = p
                }
            }
            if fleet.scanning {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text("Scanning \(fleet.sweepSize) addresses…")
                    .font(.system(size: 11)).foregroundColor(Theme.subtext)
            } else if fleet.scanned && others.isEmpty {
                Text("No other FleetView on this network")
                    .font(.system(size: 11)).foregroundColor(Theme.subtext)
            }
            // Said out loud, always — a sweep that quietly covered a slice of a large network would
            // otherwise let "none found" be read as "none there".
            if fleet.scanned && fleet.narrowed {
                Text("subnet too large — only this /24 was scanned")
                    .font(.system(size: 10)).foregroundColor(Theme.amber)
            }
            Spacer()
            if let p = state.peerSelected {
                // The address, always visible while a peer is showing. Which machine you are driving
                // is the one thing that must never be a guess — every instruction sent from here
                // lands in somebody else's live session.
                Text(p.url).font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.subtext).textSelection(.enabled)
                Button { NSWorkspace.shared.open(URL(string: p.url + "/")!) } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
                        .foregroundColor(Theme.subtext)
                }
                .buttonStyle(.plain).help("Open this peer's dashboard in a browser")
            }
            Button { Task { await state.rescanPeers() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    .foregroundColor(Theme.subtext)
            }
            .buttonStyle(.plain).disabled(fleet.scanning)
            .help("Scan the network again")
        }
        .padding(.horizontal, 18).padding(.vertical, 7)
        .background(Theme.panel.opacity(0.35))
    }

    private func tab(title: String, detail: String?, active: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundColor(Theme.subtext)
                }
            }
            .foregroundColor(active ? Theme.accent : Theme.text)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(active ? Theme.accent.opacity(0.14) : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(active ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
