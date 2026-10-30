import SwiftUI

/// One ring going out from the card when its status changes, in the colour of the new state.
/// Played once per change and never otherwise: a board that moves on its own is a board you stop
/// trusting to mean something when it moves.
private struct StatusHalo: View {
    let trigger: TermStatus
    let color: Color
    let reduceMotion: Bool

    private struct Phase { var spread: CGFloat = 0; var alpha: Double = 0 }

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(color, lineWidth: 2)
            .keyframeAnimator(initialValue: Phase(), trigger: trigger) { ring, p in
                ring.padding(-p.spread).opacity(p.alpha)
            } keyframes: { _ in
                KeyframeTrack(\.spread) {
                    CubicKeyframe(reduceMotion ? 0 : 12, duration: 0.9)
                    LinearKeyframe(0, duration: 0)
                }
                KeyframeTrack(\.alpha) {
                    LinearKeyframe(0.8, duration: 0.06)
                    CubicKeyframe(0, duration: 0.84)
                }
            }
            .allowsHitTesting(false)
    }
}

/// One terminal, as a Material 3 card.
///
/// Three rows: what it is and how it is (status shape, name, clock), what it was last asked, and
/// whose it is (agent mark, tokens). No status word and no "claude"/"codex" label — the shape and the
/// mark carry those, and the words are in the tooltips. The actions appear on hover, in a row whose
/// height is reserved either way, so no two cards in a grid are ever different heights.
struct TerminalCardView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let terminal: TerminalSession
    /// False for the copy that follows the cursor during a drag: drawn only, no gestures, and it
    /// must not report a frame — it would claim to be the card it is a picture of.
    var interactive: Bool = true

    @State private var hovering = false
    @State private var renaming = false
    /// Non-nil while the copy button is showing feedback.
    @State private var idFlash: String?
    /// Bumped when a fresh state's ten seconds run out, so the card redraws in its settled colour.
    @State private var freshTick = 0

    private var done: Bool { terminal.subtaskDone }
    private var highlighted: Bool { state.highlightedTerminalId == terminal.id }
    private var treeDropTarget: Bool { state.treeDropCardId == terminal.id }
    /// Exited or closed: still on the board, still clickable, but not live — Material's outlined
    /// card with its content at the disabled opacity.
    private var ended: Bool { terminal.status == .exited || terminal.status == .closed }

    /// How the card is filled. The colour is the state, and the same wherever the card is drawn —
    /// the 进行中 zone, its project, the recent tray. It used to be kept for the 进行中 zone alone,
    /// which left a project's cards telling running from idle by one small shape: terminals start
    /// and stop on their own, and the change was easy to miss.
    ///
    /// A change is "fresh" for `AppState.freshFor`: a run that has just started takes the light
    /// purple before settling into the deep one (see `Theme.runFresh`), and one that has just finished takes the
    /// tertiary container before settling back to an ordinary card. The finished tint is a step
    /// below running on purpose — something stopping needs you less than something going.
    private enum Look: Equatable { case runningFresh, running, needsYou, finished, plain }

    private var freshUntil: Date? {
        switch terminal.status {
        case .working: return terminal.runningSince?.addingTimeInterval(AppState.freshFor)
        case .idle:    return state.runEndedAt[terminal.id]?.addingTimeInterval(AppState.freshFor)
        default:       return nil
        }
    }

    private var look: Look {
        _ = freshTick
        let fresh = freshUntil.map { Date() < $0 } ?? false
        switch terminal.status {
        case .working:  return fresh ? .runningFresh : .running
        case .needsYou: return .needsYou
        case .idle:     return fresh ? .finished : .plain
        default:        return .plain
        }
    }

    /// Background and foreground when the card takes a colour (see `Look`).
    private var container: (bg: Color, fg: Color)? {
        switch look {
        case .runningFresh: return (Theme.runFresh, Theme.onRunFresh)
        case .running:      return (Theme.runSettled, Theme.onRunSettled)
        case .needsYou:     return (Theme.warnContainer, Theme.onWarnContainer)
        case .finished:     return (Theme.tertiaryContainer, Theme.onTertiaryContainer)
        case .plain:        return nil
        }
    }

    /// The halo's colour: the state the card just entered.
    private var haloColor: Color {
        switch look {
        case .runningFresh, .running: return Theme.primary
        case .needsYou:               return Theme.warn
        case .finished:               return Theme.tertiary
        case .plain:                  return Theme.outline
        }
    }
    private var fg: Color { container?.fg ?? Theme.onSurface }
    private var fgSecondary: Color { container.map { $0.fg.opacity(0.78) } ?? Theme.onSurfaceVariant }

    /// This card is the one being dragged: its place shows as an empty slot while the lifted copy
    /// follows the cursor.
    private var pickedUp: Bool { interactive && state.draggingTerminalId == terminal.id }

    var body: some View {
        if interactive { live } else { face }
    }

    /// The card as drawn, with nothing attached.
    private var face: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.allowsHitTesting(renaming)     // display-only unless renaming → drags pass through the name/status
            promptLine.allowsHitTesting(false)    // never let the prompt text intercept a drag
            footer                                 // keeps its buttons clickable; drag still works over it
        }
        .opacity(ended && !hovering ? Theme.endedOpacity : 1)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(ended ? Theme.outlineVariant : Color.clear, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(highlighted || treeDropTarget ? Theme.primary : Color.clear, lineWidth: 2))
        // A status change crossfades the fill; the end of the fresh window eases it more slowly,
        // since nothing happened then and it should not look as if something had.
        .animation(.easeInOut(duration: 0.45), value: terminal.status)
        .animation(.easeInOut(duration: 1.2), value: look)
    }

    private var live: some View {
        face
            .overlay(StatusHalo(trigger: terminal.status, color: haloColor, reduceMotion: reduceMotion))
            .task(id: freshUntil) {
                // Redraw once when the fresh window closes — one sleep per card that is fresh,
                // not a clock ticking on every card.
                guard let until = freshUntil, until > Date() else { return }
                try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow + 0.05))
                if !Task.isCancelled { freshTick &+= 1 }
            }
            .opacity(pickedUp ? 0 : 1)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundColor(pickedUp ? Theme.outline : Color.clear))
        .background(GeometryReader { g in            // drop target: tree node, or another card
            Color.clear.preference(key: CardFramesKey.self,
                                   value: [terminal.id: [g.frame(in: .named("fleet"))]])
        })
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
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { menuItems(inMenu: false) }
    }

    private var cardFill: Color {
        if let container { return container.bg }
        if ended { return .clear }
        return hovering ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
    }

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if look == .finished {
                    FinishedGlyph(color: container?.fg ?? Theme.tertiary, cutout: container?.bg ?? Theme.surface)
                } else {
                    StatusGlyph(status: terminal.status, onColor: container?.fg)
                }
            }
            // A new identity per state, so a change replaces the shape — the old one shrinks away
            // and the new one springs in — rather than morphing one path into an unrelated one.
            .id(look == .finished ? "finished" : terminal.status.rawValue)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.55),
                       value: look == .finished ? "finished" : terminal.status.rawValue)
            EditableText(text: terminal.name,
                         font: .fvTitleSmall,
                         color: fg,
                         onCommit: { state.renameTerminal(terminal.id, to: $0) },
                         editing: $renaming)
            Spacer(minLength: 6)
            if done {
                Image(systemName: "bookmark.fill").font(.system(size: 12))
                    .foregroundColor(container?.fg ?? Theme.tertiary)
                    .help(L(.cardMarked))
            }
            if terminal.windowHidden == true {        // window hidden, agent running: a click opens it
                Image(systemName: "eye.slash").font(.system(size: 12)).foregroundColor(fgSecondary)
                    .help(L(.cardHidden))
            }
            timeLabel
        }
        .frame(height: 20)
    }

    /// The run clock while it works; otherwise how long ago anything happened here.
    ///
    /// The clock is anchored on the run's own start, not on `.now`: `.now` is re-evaluated on every
    /// body pass, so each of the board's (many) re-renders handed the TimelineView a brand-new
    /// schedule and restarted its tick.
    @ViewBuilder private var timeLabel: some View {
        if terminal.status == .working, let since = terminal.runningSince {
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Text(RelativeTime.clock(since: since, now: ctx.date))
                    .font(.fvLabel).monospacedDigit().lineLimit(1)
                    .foregroundColor(container?.fg ?? Theme.primary)
                    .help(L(.cardRunningFor(RelativeTime.clock(since: since, now: ctx.date))))
            }
            .fixedSize()
        } else if let last = terminal.lastActivity {
            TimelineView(.periodic(from: last, by: 30)) { ctx in
                Text(RelativeTime.compact(last, now: ctx.date))
                    .font(.fvLabel).monospacedDigit().lineLimit(1)
                    .foregroundColor(fgSecondary)
                    .help(lastRunHelp)
            }
            .fixedSize()
        }
    }

    private var lastRunHelp: String {
        guard let secs = terminal.lastRunSeconds else { return L(.cardLastActivity) }
        return L(.cardLastRun(RelativeTime.clock(seconds: secs)))
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
                .font(.fvMonoBody)
                .foregroundColor(fgSecondary)
            Text(displayPrompt)
                .font(.fvBodySmall)
                .foregroundColor(fgSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(terminal.lastPrompt)      // full prompt on hover (selection removed so drag works here)
        }
        // Two lines, always: a one-line prompt must not make a shorter card than its neighbours.
        .frame(height: 32, alignment: .top)
    }

    /// Whose it is, and what it has cost — then the actions, on hover.
    private var footer: some View {
        HStack(spacing: 8) {
            idChip
            if terminal.agentKind != .unknown {
                AgentMark(kind: terminal.agentKind, tint: container?.fg)
                    .help(terminal.agentKind == .claude ? "Claude" : "Codex")
            }
            if terminal.newTokens > 0 {
                Text(TokenUsage.short(terminal.newTokens))
                    .font(.fvLabelSmall).monospacedDigit()
                    .foregroundColor(fgSecondary)
                    .help(L(.tokensHelp(terminal.newTokens)))
            }
            triggerChip
            commitChip
            Spacer(minLength: 4)
            controls
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .frame(height: 28)
    }

    /// Something will make this agent act on its own later — a schedule, or background work that
    /// wakes it. Shown always, not on hover: a card that looks idle but has a cron behind it is
    /// exactly what this is for. The alarm when anything is timed; an hourglass for work that ends
    /// on its own schedule. A click opens the panel (see TriggersPanel).
    @ViewBuilder private var triggerChip: some View {
        let all = state.triggers(for: terminal)
        if !all.isEmpty {
            let timed = all.filter(\.isTimed).count
            let open = state.triggersPanelTerminalId == terminal.id
            HStack(spacing: 3) {
                Image(systemName: timed > 0 ? "alarm" : "hourglass").font(.system(size: 10, weight: .semibold))
                Text("\(all.count)").font(.fvLabelSmall).monospacedDigit()
            }
            .foregroundColor(open ? (container?.bg ?? Theme.onPrimary) : (container?.fg ?? Theme.primary))
            .padding(.horizontal, 6).frame(height: 18)
            .background(Capsule().fill(open ? (container?.fg ?? Theme.primary) : Color.clear))
            .overlay(Capsule().strokeBorder(container?.fg.opacity(0.5) ?? Theme.primary.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
            // High priority for the same reason as the id chip: the card's own tap (raise) wants
            // this click too.
            .highPriorityGesture(TapGesture().onEnded { state.toggleTriggers(terminal.id) })
            .fixedSize()
            .help(L(.trigChipHelp(timed, all.count - timed)))
        }
    }

    /// This card's agent has committed: how many commits, and a click lists them — in whatever
    /// repository they went to. Absent until it has made one.
    @ViewBuilder private var commitChip: some View {
        if let n = state.cardCommitCounts[terminal.id], n > 0 {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold))
                Text("\(n)").font(.fvLabelSmall).monospacedDigit()
            }
            .foregroundColor(container?.fg ?? Theme.primary)
            .padding(.horizontal, 6).frame(height: 18)
            .overlay(Capsule().strokeBorder(container?.fg.opacity(0.5) ?? Theme.primary.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
            // High priority, as the trigger chip: the card's own tap (raise) wants this click too.
            .highPriorityGesture(TapGesture().onEnded { FileWindows.shared.showCommits(of: terminal, app: state) })
            .fixedSize()
            .help(L(.cardCommitsHelp(n)))
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            roundButton("iphone", help: L(.cardOpenOnPhone)) {
                state.dialog = .webLink(terminalId: terminal.id)
            }
            Menu { menuItems(inMenu: true) } label: {
                Image(systemName: "ellipsis").font(.system(size: 13))
                    .foregroundColor(fgSecondary)
                    .frame(width: 28, height: 28)
                    .background(roundFill).clipShape(Circle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L(.more))
        }
    }

    private var roundFill: Color {
        container.map { $0.fg.opacity(0.12) } ?? Theme.surfaceContainerHighest
    }

    /// The card's actions, for its context menu and for its ⋯ menu.
    @ViewBuilder private func menuItems(inMenu: Bool) -> some View {
        if inMenu {
            if terminal.status.isOpen {
                Button(L(.cardRaise)) { state.raiseTerminal(terminal.id) }
            } else {
                Button(L(.cardReopen)) { state.reopenTerminal(terminal.id) }
            }
            Button(L(.cardCopyPath)) { copyTranscriptPath() }
            Divider()
        }
        Button(L(.cardRename)) {
            if inMenu { state.requestRename(terminal.id) } else { renaming = true }
        }
        Button(state.treePanelTerminalId == terminal.id ? L(.cardCloseTree) : L(.cardOpenTree)) {
            if state.treePanelTerminalId == terminal.id { state.closeSessionTree() }
            else { state.openSessionTree(terminal.id) }
        }
        Button(L(.cardTriggers)) { state.openTriggers(terminal.id) }
        Button(L(.cardOpenFiles)) {
            FileWindows.shared.open(projectId: terminal.projectId, app: state, reveal: terminal.cwd)
        }
        Button(L(.cardCommits)) { FileWindows.shared.showCommits(of: terminal, app: state) }
        Button(L(.cardDuplicateFork)) { state.duplicateTerminal(terminal.id) }
        Button(L(.cardDuplicateBlank)) { state.duplicateTerminal(terminal.id, blank: true) }
        Button(done ? L(.cardUnmark) : L(.cardMark)) { state.toggleSubtaskDone(terminal.id) }
        if terminal.windowHidden == true {
            Button(L(.cardShowWindow)) { state.showTerminal(terminal.id) }
        } else if state.windowState(terminal.id) == .open {
            Button(L(.cardHideWindow)) { state.hideTerminal(terminal.id) }
        }
        if terminal.clusterId != nil {
            Button(L(.cardLeaveCluster)) { state.removeFromCluster(terminal.id) }
        }
        Divider()
        Button(L(.cardRemove), role: .destructive) { state.removeTerminal(terminal.id) }
    }

    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func copyTranscriptPath() {
        // `transcriptPath(for:)`, not the stored `transcriptPath`: it resolves Codex from its
        // rollouts ahead of the hook pointer, which is the case where the stored value is silently
        // frozen on a file from days ago.
        if let path = state.transcriptPath(for: terminal.id) {
            copyToClipboard(path)
            flashId("path")
        } else {
            // Said out loud rather than copying an empty string: a card that only ever held a
            // shell has no conversation, and silence looks like a failed copy.
            flashId("none")
        }
    }

    /// The terminal's id, bottom left: four characters and an ellipsis, so it is never the thing
    /// that gives way. Click copies the whole UUID (what `project-manager` takes); double-click copies
    /// the conversation file's path. Four characters still resolve a terminal for `project-manager`.
    ///
    /// One exclusive gesture, not two `onTapGesture`s, and high-priority so it beats the card: two
    /// stacked taps fire the single on the first click and the double never forms, and the card's
    /// own tap (raise) competes for the same click from above.
    private var idChip: some View {
        let short = String(terminal.id.uuidString.prefix(4)).lowercased() + "…"
        let flash: String? = idFlash.map {
            switch $0 {
            case "id":   return L(.idCopied)
            case "path": return L(.idPathCopied)
            default:     return L(.idNoLog)
            }
        }
        return Text(flash ?? short)
            .font(.fvMono)
            .lineLimit(1)
            .foregroundColor(idFlash != nil ? (container?.fg ?? Theme.primary) : fgSecondary)
            // The whole chip, not just its glyphs: five 11pt characters are a small target.
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture(count: 2).onEnded { copyTranscriptPath() }
                    .exclusively(before: TapGesture().onEnded {
                        copyToClipboard(terminal.id.uuidString.lowercased())
                        flashId("id")
                    })
            )
            .fixedSize()
            .help(L(.idHelp(String(terminal.id.uuidString.prefix(8)).lowercased())))
    }

    private func flashId(_ text: String) {
        idFlash = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { idFlash = nil }
    }

    private func roundButton(_ name: String, help: String,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12))
                .foregroundColor(fgSecondary)
                .frame(width: 28, height: 28)
                .background(roundFill).clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// The agent's own mark, small: Claude's starburst in its clay, Codex's hexagon in plain ink.
/// Identity, not status — it never colours a border or a fill.
struct AgentMark: View {
    let kind: AgentKind
    var tint: Color? = nil
    var size: CGFloat = 13

    var body: some View {
        Group {
            switch kind {
            case .claude:
                ClaudeMark().stroke(tint ?? Theme.claudeTint,
                                    style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
            case .codex:
                ZStack {
                    Hexagon().stroke(tint ?? Theme.codexTint,
                                     style: StrokeStyle(lineWidth: size * 0.12, lineJoin: .round))
                    Circle().fill(tint ?? Theme.codexTint).frame(width: size * 0.22, height: size * 0.22)
                }
            case .unknown:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
    }
}

private struct ClaudeMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2 * 0.9
        for i in 0..<4 {
            let a = Double(i) * .pi / 4
            p.move(to: CGPoint(x: c.x + R * cos(a), y: c.y + R * sin(a)))
            p.addLine(to: CGPoint(x: c.x - R * cos(a), y: c.y - R * sin(a)))
        }
        return p
    }
}

private struct Hexagon: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2 * 0.9
        for i in 0..<6 {
            let a = Double(i) * .pi / 3 - .pi / 2
            let pt = CGPoint(x: c.x + R * cos(a), y: c.y + R * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

struct StatusDot: View {
    let status: TermStatus
    var onColor: Color? = nil

    var body: some View { StatusGlyph(status: status, onColor: onColor) }
}
