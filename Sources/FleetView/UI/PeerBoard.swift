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

/// The selected peer's terminals, in the sidebar's TASKS slot.
///
/// Grouped by project and read-only. The rows do not open anything: a terminal on another machine
/// is reached through that machine's board, which is already filling the content column beside
/// this list — a second, subtly different way in would only be a way to be surprised.
struct PeerTaskList: View {
    @EnvironmentObject var state: AppState
    let peer: Peer

    /// Project name → its terminals, in the order the peer reported them.
    private var groups: [(name: String, terms: [PeerTerminal])] {
        var order: [String] = []
        var byProject: [String: [PeerTerminal]] = [:]
        for t in state.peerTerminals {
            let key = t.project.isEmpty ? "—" : t.project
            if byProject[key] == nil { order.append(key) }
            byProject[key, default: []].append(t)
        }
        return order.map { ($0, byProject[$0] ?? []) }
    }

    var body: some View {
        if state.peerTerminals.isEmpty {
            Text(state.peerNotesLoading ? L(.peerReading(peer.label)) : L(.peerNoTerminals(peer.label)))
                .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .padding(.horizontal, 18).padding(.top, 6)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.name) { g in
                        SidebarGroupHeader(name: g.name)
                        ForEach(g.terms) { t in row(t).padding(.leading, Sidebar.rowIndent) }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// The same row as this Mac's (TaskRow), read-only: the shape, the name, and the shape's word in
    /// the tooltip rather than beside it.
    private func row(_ t: PeerTerminal) -> some View {
        let status = TermStatus(rawValue: t.status) ?? .closed
        let ended = status == .exited || status == .closed
        return HStack(spacing: 12) {
            StatusGlyph(status: status)
            NameText(name: t.name.isEmpty ? String(t.id.prefix(8)) : t.name, font: .fvBody)
                .foregroundColor(ended ? Theme.onSurfaceVariant : Theme.onSurface)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .contentShape(Rectangle())
        .help("\(t.name) · \(status.label)")
    }
}

/// The switcher under the top bar: this machine, then every FleetView found on the LAN.
struct PeerStrip: View {
    @EnvironmentObject var state: AppState
    /// Observed explicitly: discovery publishes from its own object, and a view watching only
    /// AppState would sit on an empty list while the scan filled it in.
    @ObservedObject var fleet: PeerFleet

    private var others: [Peer] { fleet.found.filter { !$0.isSelf } }

    /// Two FleetViews run by the same account would both be called by that account's name, and a
    /// tab you cannot tell apart from its neighbour is one you will click by mistake. Then the host
    /// is added, which is the thing that actually differs.
    private func title(_ p: Peer) -> String {
        others.filter { $0.label == p.label }.count > 1 ? "\(p.label) · \(p.host)" : p.label
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                tab(title: L(.peerThisMac), detail: nil, active: state.peerSelected == nil) {
                    state.selectPeer(nil)
                }
                ForEach(others) { p in
                    tab(title: title(p), detail: "\(p.terminals)",
                        active: state.peerSelected?.id == p.id) {
                        state.selectPeer(p)
                    }
                    .help(p.working > 0 ? L(.peerHelpWorking(p.url, p.terminals, p.working))
                                        : L(.peerHelp(p.url, p.terminals)))
                }
            }
            .padding(3)
            .frame(height: Theme.controlHeight)
            .background(Theme.surfaceContainerHigh).clipShape(Capsule())
            if fleet.scanning {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text(L(.peerScanning(fleet.sweepSize)))
                    .font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
            } else if fleet.scanned && others.isEmpty {
                Text(L(.peerNone))
                    .font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
            }
            // Said out loud, always — a sweep that quietly covered a slice of a large network would
            // otherwise let "none found" be read as "none there".
            if fleet.scanned && fleet.narrowed {
                Text(L(.peerNarrowed))
                    .font(.fvLabelSmall).foregroundColor(Theme.warn)
            }
            if let p = state.peerSelected {
                // Which machine you are driving is the one thing that must never be a guess — every
                // instruction sent from here lands in somebody else's live session.
                Text(p.url).font(.fvMono)
                    .foregroundColor(Theme.onSurfaceVariant).textSelection(.enabled).lineLimit(1)
                stripButton("arrow.up.forward.square", help: L(.peerOpenBrowser)) {
                    NSWorkspace.shared.open(URL(string: p.url + "/")!)
                }
            }
            stripButton("arrow.clockwise", help: L(.peerRescan)) { Task { await state.rescanPeers() } }
                .disabled(fleet.scanning)
            stripButton("xmark", help: L(.collapse)) { state.togglePeerStrip() }
        }
    }

    private func tab(title: String, detail: String?, active: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.fvLabel).lineLimit(1)
                if let detail {
                    Text(detail).font(.fvLabelSmall).monospacedDigit()
                        .foregroundColor(active ? Theme.onSecondaryContainer.opacity(0.75) : Theme.onSurfaceVariant)
                }
            }
            .foregroundColor(active ? Theme.onSecondaryContainer : Theme.onSurface)
            .padding(.horizontal, 12).frame(height: Theme.controlHeight - 6)
            .background(active ? Theme.secondaryContainer : Color.clear)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func stripButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundColor(Theme.onSurfaceVariant)
                .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                .background(Theme.surfaceContainerHigh).clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}
