import SwiftUI

struct TerminalCardView: View {
    @EnvironmentObject var state: AppState
    let terminal: TerminalSession

    @State private var hovering = false
    @State private var renaming = false
    @State private var showRemote = false
    @State private var remoteEndpoint: RemoteServer.Endpoint?
    @State private var remoteQR: NSImage?

    private var cluster: Cluster? { state.cluster(terminal.clusterId) }
    private var done: Bool { terminal.subtaskDone }
    private var highlighted: Bool { state.highlightedTerminalId == terminal.id }
    private var cardStroke: Color {
        if done { return Theme.doneStroke.opacity(0.55) }
        if terminal.agentKind != .unknown { return Theme.agentColor(terminal.agentKind).opacity(0.5) }
        return Theme.stroke
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header.allowsHitTesting(renaming)     // display-only unless renaming → drags pass through the name/status
            promptLine.allowsHitTesting(false)    // never let the prompt text intercept a drag
            Divider().overlay(done ? Theme.doneStroke.opacity(0.25) : Theme.stroke)
            footer                                 // keeps its buttons clickable; drag still works over it
        }
        .padding(14)
        .background(done ? Theme.doneCard : (hovering ? Theme.cardHover : Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(cardStroke, lineWidth: done ? 1.5 : 1))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(highlighted ? Theme.accent : Color.clear, lineWidth: 2))
        .shadow(color: highlighted ? Theme.accent.opacity(0.45) : .clear, radius: highlighted ? 9 : 0)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture { if !renaming { state.raiseTerminal(terminal.id) } }
        // Plain drag, NO long-press: on macOS a click-drag never scrolls a ScrollView, so the drag can
        // begin the instant the pointer moves a few px. Requiring a press-and-hold first is what made
        // dragging feel broken ("often invalid"). A pure click (no movement) still falls through to the
        // tap above (raise), and simultaneousGesture lets the drag start even over the action buttons.
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("fleet"))
                .onChanged { value in state.dragChanged(terminal.id, to: value.location) }
                .onEnded { value in state.dragEnded(at: value.location) }
        )
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: terminal.status)
        .animation(.easeOut(duration: 0.2), value: done)
        .animation(.easeOut(duration: 0.2), value: highlighted)
        .contextMenu {
            Button("Rename…") { renaming = true }
            Button("Duplicate (cluster)") { state.duplicateTerminal(terminal.id) }
            Button(done ? "Mark Not Done" : "Mark Done") { state.toggleSubtaskDone(terminal.id) }
            if terminal.clusterId != nil {
                Button("Remove from Cluster") { state.removeFromCluster(terminal.id) }
            }
            Divider()
            Button("Remove Terminal", role: .destructive) { state.removeTerminal(terminal.id) }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            StatusDot(status: terminal.status)
            EditableText(text: terminal.name,
                         font: .system(size: 14, weight: .semibold),
                         color: Theme.text,
                         onCommit: { state.renameTerminal(terminal.id, to: $0) },
                         editing: $renaming)
            Spacer(minLength: 6)
            if terminal.agentKind != .unknown {
                Text(terminal.agentKind.label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.agentColor(terminal.agentKind))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.agentColor(terminal.agentKind).opacity(0.16))
                    .clipShape(Capsule())
            }
            if done {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundColor(Theme.green)
            }
            Text(terminal.status.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.statusColor(terminal.status))
        }
    }

    // Collapse whitespace and hard-cap length so a very long prompt can't overflow the card.
    private var displayPrompt: String {
        guard !terminal.lastPrompt.isEmpty else { return "—" }
        let collapsed = terminal.lastPrompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 220 ? String(collapsed.prefix(220)) + "…" : collapsed
    }

    private var promptLine: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(terminal.status == .shell ? "$" : "›")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(terminal.status == .shell ? Theme.statusColor(.shell) : Theme.subtext.opacity(0.7))
                .padding(.top, 1)
            Text(displayPrompt)
                .font(.system(size: 12))
                .foregroundColor(terminal.lastPrompt.isEmpty ? Theme.subtext.opacity(0.5) : Theme.subtext)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(terminal.lastPrompt)      // full prompt on hover (selection removed so drag works here)
        }
        .frame(minHeight: 34, alignment: .top)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if done {
                Text("done")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.green.opacity(0.18)).foregroundColor(Theme.green)
                    .clipShape(Capsule())
            }
            if terminal.lastActivity != nil {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    Text(RelativeTime.short(terminal.lastActivity, now: ctx.date) ?? "")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.subtext.opacity(0.7))
                        .help("Last activity in this terminal")
                }
            }
            Spacer(minLength: 4)
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 13) {
            iconButton(done ? "checkmark.circle.fill" : "circle",
                       active: done, help: done ? "Mark not done" : "Mark subtask done") {
                state.toggleSubtaskDone(terminal.id)
            }
            if terminal.status.isOpen {
                iconButton("arrow.up.left.square", help: "Raise to front") { state.raiseTerminal(terminal.id) }
            } else {
                iconButton("play.circle", help: "Reopen terminal") { state.reopenTerminal(terminal.id) }
            }
            iconButton("plus.square.on.square", help: "Duplicate (cluster)") { state.duplicateTerminal(terminal.id) }
            iconButton("globe", active: showRemote, help: "Open on another device (web)") {
                showRemote.toggle()
            }
            .popover(isPresented: $showRemote, arrowEdge: .bottom) { remotePopover }
            Menu {
                Button("Rename…") { state.requestRename(terminal.id) }
                if terminal.clusterId != nil {
                    Button("Remove from Cluster") { state.removeFromCluster(terminal.id) }
                }
                Divider()
                Button("Remove Terminal", role: .destructive) { state.removeTerminal(terminal.id) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundColor(Theme.subtext)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    // MARK: - Remote (web) access popover

    private var remotePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open on another device")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.text)

            if !state.remote.available {
                Text("Web access needs two command-line tools. Install them, then relaunch FleetView:")
                    .font(.system(size: 11)).foregroundColor(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(state.remote.unavailableReason)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundColor(Theme.text)
                    Button("Copy") { copyToClipboard(state.remote.unavailableReason) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Theme.accent)
                }
                .padding(8).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let ep = remoteEndpoint {
                if let qr = remoteQR {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable().frame(width: 176, height: 176)
                        .padding(8).background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Text("Scan with your phone, or open this link on any device on the same Wi-Fi:")
                    .font(.system(size: 11)).foregroundColor(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(ep.url)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        .foregroundColor(Theme.text)
                    Spacer(minLength: 4)
                    Button("Copy") { copyToClipboard(ep.url) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Theme.accent)
                    Button("Open") { NSWorkspace.shared.open(URL(string: ep.url)!) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Theme.accent)
                }
                .padding(8).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 6))
                Label("LAN only — anyone on your network with this link can control this terminal.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundColor(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Couldn't start the web server. Make sure the terminal is open and you're on a network.")
                    .font(.system(size: 11)).foregroundColor(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 250)
        .onAppear {
            guard state.remote.available else { return }
            let ep = state.remoteEndpoint(for: terminal.id)
            remoteEndpoint = ep
            remoteQR = ep.map { QRCode.image(for: $0.url) } ?? nil
        }
    }

    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func iconButton(_ name: String, active: Bool = false, help: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13))
                .foregroundColor(active ? Theme.green : Theme.subtext)
        }
        .buttonStyle(.plain).help(help)
    }
}

struct StatusDot: View {
    let status: TermStatus
    @State private var pulse = false

    var body: some View {
        ZStack {
            if status == .working {
                Circle().fill(Theme.statusColor(status).opacity(0.35))
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.0 : 0.5)
                    .opacity(pulse ? 0.0 : 0.6)
            }
            Circle().fill(Theme.statusColor(status)).frame(width: 9, height: 9)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            if status == .working {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
            }
        }
    }
}
