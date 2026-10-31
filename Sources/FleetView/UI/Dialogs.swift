import SwiftUI
import AppKit

/// A centred dialog over the window. One at a time; `AppState.dialog` says which.
///
/// These were popovers, and a popover leaves the board behind it at full strength, so a QR code
/// floating over a grid of cards read as one more card. A dialog recedes everything behind it the
/// same way search and the session tree do (see `DashboardView.dashboardReceded`), and closes the
/// same way: Esc, or a click on the dimmed area.
enum AppDialog: Identifiable, Equatable {
    /// Open the dashboard on a phone. With a terminal, the link goes straight to that terminal's
    /// conversation (`#t=<id>`), exactly where tapping its card on the dashboard would land.
    case webLink(terminalId: UUID?)
    /// Stop every terminal (and optionally the board), with the quit setting beside it.
    case closeAll
    /// Where a shared conversation is published (FleetView → 分享设置…).
    case shareSettings

    var id: String {
        switch self {
        case .webLink(let t): return "webLink-\(t?.uuidString ?? "board")"
        case .closeAll:       return "closeAll"
        case .shareSettings:  return "shareSettings"
        }
    }
}

/// Hosts whatever `state.dialog` holds: the click catcher, the Esc binding, and the card.
struct DialogHost: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let dialog = state.dialog {
            ZStack {
                // Catcher only — the dashboard's recede supplies the dimming.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { state.dialog = nil }
                Group {
                    switch dialog {
                    case .webLink(let terminalId):
                        WebLinkDialog(terminalId: terminalId)
                    case .closeAll:
                        CloseAllDialog()
                    case .shareSettings:
                        ShareSettingsDialog()
                    }
                }
                .background(Theme.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.dialog))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            }
            .background {
                Button("") { state.dialog = nil }.keyboardShortcut(.cancelAction).hidden()
            }
            .transition(.opacity)
        }
    }
}

/// "在手机上打开": a QR code for the web dashboard, or for one terminal's conversation on it.
///
/// It used to hand out the terminal's raw ttyd page on a port of its own, which is not what tapping
/// that terminal on the dashboard shows and needed ttyd installed. The dashboard link needs only the
/// web server, and the chat is the view a phone is actually for.
struct WebLinkDialog: View {
    @EnvironmentObject var state: AppState
    let terminalId: UUID?

    @State private var pick: String?
    @State private var qr: NSImage?
    @State private var copied = false

    private var terminal: TerminalSession? {
        terminalId.flatMap { id in state.terminals.first { $0.id == id } }
    }

    /// The `#t=` suffix the web page reads to open a conversation directly.
    private var suffix: String { terminalId.map { "#t=\($0.uuidString)" } ?? "" }

    var body: some View {
        let addresses = state.webDashboardAddresses
        let picked = addresses.first { $0.url == pick } ?? addresses.first
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "iphone").font(.system(size: 16)).foregroundColor(Theme.accent)
                Text(L(.webTitle)).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                Spacer()
                Button { state.dialog = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.onSurfaceVariant).frame(width: 32, height: 32).contentShape(Circle())
                }
                .buttonStyle(.plain).help(L(.closeEsc))
            }
            Text(subtitle)
                .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4).padding(.bottom, 14)

            if let picked {
                if addresses.count > 1 {
                    HStack(spacing: 2) {
                        ForEach(addresses) { address in
                            let on = address.url == picked.url
                            Button { select(address.url) } label: {
                                Text(address.label).font(.fvLabel)
                                    .foregroundColor(on ? Theme.onSecondaryContainer : Theme.onSurfaceVariant)
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .background(on ? Theme.secondaryContainer : Color.clear)
                                    .clipShape(Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(address.reach)
                        }
                    }
                    .padding(3)
                    .background(Theme.surfaceContainerHighest).clipShape(Capsule())
                    .padding(.bottom, 14)
                }
                if let qr {
                    Image(nsImage: qr).interpolation(.none).resizable()
                        .frame(width: 168, height: 168)
                        .padding(10).background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 14)
                }
                HStack(spacing: 6) {
                    Text(picked.url + suffix)
                        .font(.fvMono)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        .foregroundColor(Theme.onSurface)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: Theme.controlHeight, alignment: .leading)
                        .background(Theme.surfaceContainerHighest).clipShape(Capsule())
                    roundButton(copied ? "checkmark" : "doc.on.doc", help: L(.copyLink)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(picked.url + suffix, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                    // Deliberately localhost: opening it on the Mac that serves it should not depend
                    // on the Mac routing back to itself through Tailscale or the router.
                    roundButton("arrow.up.right.square", help: L(.openOnThisMac)) {
                        if let url = URL(string: "http://localhost:\(state.web.port)/\(suffix)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Label(terminalId == nil ? L(.webReachAll(picked.reach)) : L(.webReachOne(picked.reach)),
                      systemImage: "info.circle")
                    .font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            } else {
                Text(L(.webOffline))
                    .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 22)
        .frame(width: 404)
        .onAppear {
            // Re-read on every open: the tailnet goes up and down, and Wi-Fi changes address.
            select(addresses.first { $0.url == pick }?.url ?? addresses.first?.url)
        }
    }

    private var subtitle: String {
        if let terminal {
            return L(.webSubtitleTerminal(terminal.name))
        }
        return L(.webSubtitleBoard)
    }

    private func select(_ url: String?) {
        pick = url
        qr = url.flatMap { QRCode.image(for: $0 + suffix) }
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundColor(Theme.onSurfaceVariant)
                .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                .background(Theme.surfaceContainerHighest).clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// "关闭所有终端": what it stops, what it keeps, and the quit-time setting that automates it.
struct CloseAllDialog: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let open = state.openTerminalCount
        let working = state.terminals.filter { $0.status == .working }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "power").font(.system(size: 16)).foregroundColor(Theme.error)
                Text(L(.closeAllTitle)).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                Spacer()
            }
            .padding(.bottom, 12)
            Text(open > 0 ? L(.closeAllRunning(open)) : L(.closeAllNone))
                .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            // The one thing that makes this safe to press: nothing is lost from the board.
            Label(L(.closeAllKeepsCards),
                  systemImage: "arrow.uturn.backward")
                .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if working > 0 {
                Label(L(.closeAllInterrupts(working)), systemImage: "exclamationmark.triangle.fill")
                    .font(.fvBodySmall).foregroundColor(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            Toggle(isOn: Binding(get: { state.closeTerminalsOnQuit },
                                 set: { state.closeTerminalsOnQuit = $0; state.save() })) {
                Text(L(.closeOnQuit)).font(.fvBodySmall).foregroundColor(Theme.onSurface)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 16)
            Text(state.closeTerminalsOnQuit ? L(.closeOnQuitOn) : L(.closeOnQuitOff))
                .font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack(spacing: 8) {
                // Secondary by design, and behind its own alert: it sits beside the main action and
                // does something that action explicitly does not — throw the board away.
                Button {
                    state.dialog = nil
                    BoardActions.confirmClear(state, reason: "topbar")
                } label: {
                    Text(L(.clearBoardEllipsis)).font(.fvLabel).foregroundColor(Theme.error)
                        .padding(.horizontal, 12).frame(height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L(.clearBoardHelp))
                Spacer()
                Button { state.dialog = nil } label: {
                    Text(L(.cancel)).font(.fvLabel).foregroundColor(Theme.primary)
                        .padding(.horizontal, 16).frame(height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    state.dialog = nil
                    state.closeAllTerminals(reason: "topbar")
                } label: {
                    Text(L(.closeAllButton)).font(.fvLabel).lineLimit(1).fixedSize().foregroundColor(Theme.onPrimary)
                        .padding(.horizontal, 20).frame(height: 40)
                        .background(Theme.error).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 420)
    }
}

/// Where "share" publishes a conversation. FleetView itself serves only the LAN, so a link anyone can
/// open is minted by a service of the user's own (see ShareService for what it must answer, and
/// examples/share-server.mjs for one that does). With nothing set, sharing offers a download only.
struct ShareSettingsDialog: View {
    @EnvironmentObject var state: AppState
    @State private var endpoint = ShareService.config()?.endpoint ?? ""
    @State private var token = ShareService.config()?.token ?? ""
    @State private var testing = false
    @State private var verdict: (ok: Bool, text: String)?

    private var draft: ShareService.Config? {
        let e = endpoint.trimmingCharacters(in: .whitespaces), t = token.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty, !t.isEmpty, let u = URL(string: e), u.scheme == "http" || u.scheme == "https",
              u.host != nil else { return nil }
        return ShareService.Config(endpoint: e, token: t)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 16)).foregroundColor(Theme.primary)
                Text(L(.shareSettingsTitle)).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                Spacer()
            }
            .padding(.bottom, 12)
            Text(L(.shareSettingsBody)).font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(L(.shareSettingsEndpoint)).font(.fvLabel).foregroundColor(Theme.onSurface)
                TextField("https://example.com", text: $endpoint).textFieldStyle(.roundedBorder)
                Text(L(.shareSettingsToken)).font(.fvLabel).foregroundColor(Theme.onSurface).padding(.top, 6)
                SecureField("", text: $token).textFieldStyle(.roundedBorder)
            }
            .padding(.top, 14)
            Text(L(.shareSettingsProtocol)).font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(.top, 10)
            if let verdict {
                Label(verdict.text, systemImage: verdict.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.fvBodySmall).foregroundColor(verdict.ok ? Theme.primary : Theme.error)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.top, 10)
            }
            HStack(spacing: 8) {
                Button { test() } label: {
                    HStack(spacing: 6) {
                        if testing { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12) }
                        Text(L(.shareSettingsTest)).font(.fvLabel)
                    }
                    .foregroundColor(Theme.primary).padding(.horizontal, 12).frame(height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(draft == nil || testing)
                if ShareService.config() != nil {
                    Button {
                        try? ShareService.save(nil)
                        endpoint = ""; token = ""; verdict = nil
                    } label: {
                        Text(L(.shareSettingsClear)).font(.fvLabel).foregroundColor(Theme.error)
                            .padding(.horizontal, 12).frame(height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { state.dialog = nil } label: {
                    Text(L(.cancel)).font(.fvLabel).foregroundColor(Theme.primary)
                        .padding(.horizontal, 16).frame(height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    do {
                        try ShareService.save(draft)
                        state.dialog = nil
                    } catch {
                        verdict = (false, error.localizedDescription)
                    }
                } label: {
                    Text(L(.save)).font(.fvLabel).foregroundColor(Theme.onPrimary)
                        .padding(.horizontal, 20).frame(height: 40)
                        .background(Theme.primary).clipShape(Capsule())
                }
                .buttonStyle(.plain).disabled(draft == nil).opacity(draft == nil ? 0.5 : 1)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 480)
    }

    private func test() {
        guard let c = draft else { return }
        testing = true; verdict = nil
        ShareService.test(c) { r in
            Task { @MainActor in
                testing = false
                switch r {
                case .success(let url): verdict = (true, L(.shareSettingsWorks(url)))
                case .failure(let f): verdict = (false, f.message)
                }
            }
        }
    }
}
