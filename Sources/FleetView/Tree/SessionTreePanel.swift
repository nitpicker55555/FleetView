import SwiftUI
import AppKit

/// The right-hand "对话树" panel: a GitUp-style vertical lane graph of one agent session's
/// prompt tree — active branch in accent, each side branch in its own palette colour, current
/// leaf pulsing. Rows drag onto the fleet board to fork-open that node in a new terminal.
struct SessionTreePanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: SessionTreeModel

    @State private var copiedSid = false
    @State private var copiedTid = false
    @FocusState private var searchFocused: Bool

    /// A click-to-copy id card. Session and terminal ids sit side by side so it is always clear
    /// WHICH conversation and WHICH terminal this tree belongs to.
    private func idChip(label: String, value: String, copied: Binding<Bool>, mono: Bool,
                        glyph: TermStatus? = nil) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied.wrappedValue = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { copied.wrappedValue = false }
        } label: {
            HStack(spacing: 6) {
                if let glyph { StatusGlyph(status: glyph, size: 12) }
                else { Image(systemName: copied.wrappedValue ? "checkmark" : "doc.on.doc").font(.system(size: 11)) }
                Text(copied.wrappedValue ? L(.copied) : label)
                    .font(mono && !copied.wrappedValue ? .fvMono : .fvLabel).lineLimit(1)
            }
            .foregroundColor(Theme.onSurfaceVariant)
            .padding(.horizontal, 10).frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).strokeBorder(Theme.outlineVariant, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(L(.treeCopyId))
    }

    private func metaChip(_ symbol: String, _ text: String, help: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(.fvLabel).monospacedDigit()
        }
        .foregroundColor(Theme.onSurfaceVariant)
        .padding(.horizontal, 10).frame(height: 28)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).strokeBorder(Theme.outlineVariant, lineWidth: 1))
        .help(help)
    }

    private var boundTerminal: TerminalSession? {
        state.terminals.first { $0.id == state.treePanelTerminalId }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let reason = model.emptyReason {
                emptyState(reason)
            } else if model.loading && model.rows.isEmpty {
                loadingState
            } else {
                searchField
                treeList
            }
        }
        .background(Theme.panel)
        // Esc peels one layer at a time: a pinned card first, then the panel.
        .onExitCommand { model.selected != nil ? (model.selected = nil) : state.closeSessionTree() }
        .background {                                            // ⌘F focus search · ⌘↓ jump to leaf
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden()
            Button("") { jumpToLeaf.toggle() }
                .keyboardShortcut(.downArrow, modifiers: .command).hidden()
        }
    }

    /// Toggled by ⌘↓ — observed by the scroll reader to jump back to the current leaf.
    @State private var jumpToLeaf = false

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 15)).foregroundColor(Theme.primary)
                Text(L(.treeTitle)).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                if model.loading { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Spacer()
                Button { state.closeSessionTree() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .frame(width: 32, height: 32).contentShape(Circle())
                }
                .buttonStyle(.plain).help(L(.closeEsc))
            }
            HStack(spacing: 6) {
                if model.emptyReason == nil {
                    metaChip("arrow.triangle.branch", "\(model.tree.branchPoints)", help: L(.treeBranchPoints))
                    metaChip("bubble.left", "\(model.tree.nodeCount)", help: L(.treeTurns))
                }
                if let sid = model.boundSessionId {
                    idChip(label: String(sid.prefix(8)), value: sid, copied: $copiedSid, mono: true)
                }
                if let t = boundTerminal {
                    idChip(label: t.name, value: t.id.uuidString.lowercased(), copied: $copiedTid,
                           mono: false, glyph: t.status)
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14))
                .foregroundColor(Theme.onSurfaceVariant)
            TextField(L(.treeSearch), text: $model.query)
                .textFieldStyle(.plain).font(.fvBody).foregroundColor(Theme.onSurface)
                .focused($searchFocused)
                .onExitCommand { model.query = "" }
            if !model.query.isEmpty {
                Text("\(model.rows.count)").font(.fvLabelSmall).monospacedDigit()
                    .foregroundColor(Theme.onSurfaceVariant)
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                        .foregroundColor(Theme.onSurfaceVariant)
                }.buttonStyle(.plain).help(L(.clear))
            }
            Button { model.searchAnswers.toggle() } label: {
                HStack(spacing: 4) {
                    if model.searchAnswers { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                    Text(L(.treeWithReplies)).font(.fvLabelSmall)
                }
                .foregroundColor(model.searchAnswers ? Theme.onSecondaryContainer : Theme.onSurfaceVariant)
                .padding(.horizontal, 10).frame(height: 26)
                .background(model.searchAnswers ? Theme.secondaryContainer : Color.clear)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain).help(L(.treeWithRepliesHelp))
            Button { model.newestFirst.toggle() } label: {
                Image(systemName: model.newestFirst ? "arrow.down" : "arrow.up")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(Theme.onSurfaceVariant)
                    .frame(width: 26, height: 26).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.newestFirst ? L(.treeNewestFirst) : L(.treeOldestFirst))
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .frame(height: Theme.controlHeight)
        .background(Theme.surfaceContainerHigh)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(searchFocused ? Theme.primary : Color.clear, lineWidth: 1))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    // MARK: Tree

    private var treeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        TreeRowView(row: row, model: model)
                            .environmentObject(state)
                            .id(row.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.tree.activeLeafNode) { _, leaf in
                if let leaf {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(leaf, anchor: model.newestFirst ? .top : .bottom)
                    }
                }
            }
            .onChange(of: jumpToLeaf) { _, _ in
                if let leaf = model.tree.activeLeafNode {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(leaf, anchor: model.newestFirst ? .top : .bottom)
                    }
                }
            }
            .onAppear {
                if let leaf = model.tree.activeLeafNode {
                    proxy.scrollTo(leaf, anchor: model.newestFirst ? .top : .bottom)
                }
            }
        }
    }

    // MARK: States

    private func emptyState(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 28, weight: .light)).foregroundColor(Theme.subtext.opacity(0.5))
            Text(reason).font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.regular)
            Text(L(.treeLoading)).font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - One row

struct TreeRowView: View {
    @EnvironmentObject var state: AppState
    let row: TreeRow
    @ObservedObject var model: SessionTreeModel
    @State private var hover = false

    private var node: TreeTurn? { row.nodeUuid.flatMap { model.tree.nodes[$0] } }
    private var isSelected: Bool { row.nodeUuid != nil && model.selected == row.nodeUuid }


    var body: some View {
        switch row.kind {
        case .fold(let id, let hidden):
            foldRow(id: id, count: hidden.count)
        case .compacted(let boundary, let turns):
            compactedRow(boundary: boundary, turns: turns)
        case .versions(let id, let uuids):
            versionsRow(id: id, count: uuids.count)
        case .node:
            nodeRow
        }
    }

    private func foldRow(id: String, count: Int) -> some View {
        HStack(spacing: 0) {
            TreeRailView(row: row, rowHeight: 32, hasChips: false, flipped: model.newestFirst)
                .frame(width: TreeLane.railWidth, height: 32)
            Button {
                withAnimation(.easeOut(duration: 0.18)) { model.expandFold(id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                    Text(L(.treeNTurns(count))).font(.fvLabel)
                }
                .foregroundColor(Theme.onSurfaceVariant)
                .padding(.horizontal, 12).frame(height: 26)
                .overlay(Capsule().strokeBorder(Theme.outlineVariant, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).help(L(.treeExpandFold(count)))
            Spacer(minLength: 0)
        }
        .frame(height: 32)
    }

    /// The top of a compacted session. The conversation did not start here — it was summarised into
    /// the turn below and carried on — and until now the panel had no way to say so, let alone to
    /// show what was summarised. Deliberately louder than a fold pill: a fold hides turns you
    /// watched scroll past, this one is the rest of the conversation.
    ///
    /// With `turns` nil the earlier half is not on this machine any more. It still gets a row,
    /// greyed and inert: "there is nothing behind this" is the answer to the question the
    /// "continued from" turn below raises, and an empty space answers it the same way as a
    /// conversation that simply started there.
    private func compactedRow(boundary: String, turns: Int?) -> some View {
        HStack(spacing: 0) {
            TreeRailView(row: row, rowHeight: 34, hasChips: false, flipped: model.newestFirst)
                .frame(width: TreeLane.railWidth, height: 34)
            if let turns {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { model.expandCompaction(boundary) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11))
                        Text(L(.treeExpandCompaction(turns))).font(.fvLabel)
                    }
                    .foregroundColor(Theme.onSecondaryContainer)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Theme.secondaryContainer).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L(.treeExpandCompactionHelp(turns)))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.xmark").font(.system(size: 11))
                    Text(L(.treeCompactionGone)).font(.fvLabel)
                }
                .foregroundColor(Theme.onSurfaceVariant)
                .padding(.horizontal, 12).frame(height: 28)
                .overlay(Capsule().strokeBorder(Theme.outlineVariant, lineWidth: 1))
                .help(L(.treeCompactionGoneHelp))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 34)
    }

    private func versionsRow(id: String, count: Int) -> some View {
        HStack(spacing: 0) {
            TreeRailView(row: row, rowHeight: 34, hasChips: false, flipped: model.newestFirst)
                .frame(width: TreeLane.railWidth, height: 34)
            Button {
                withAnimation(.easeOut(duration: 0.18)) { model.expandVersions(id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.on.square").font(.system(size: 11))
                    Text(L(.treeVersions(count))).font(.fvLabel)
                }
                .foregroundColor(Theme.onSurfaceVariant)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L(.treeVersionsHelp(count + 1)))
            Spacer(minLength: 0)
        }
        .frame(height: 34)
    }

    private var nodeRow: some View {
        let chips = row.nodeUuid.flatMap { model.chips[$0] } ?? []
        let rowHeight: CGFloat = chips.isEmpty ? 54 : 70
        return HStack(alignment: .top, spacing: 0) {
            TreeRailView(row: row, rowHeight: rowHeight, hasChips: !chips.isEmpty,
                         flipped: model.newestFirst)
                .frame(width: TreeLane.railWidth, height: rowHeight)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if model.searching, let n = node {
                        let h = model.hits(n)
                        if h.prompt { hitBadge("prompt", Theme.accent) }
                        if h.answer { hitBadge(L(.treeHitReply), Theme.tertiary) }
                    }
                    // Codex's half of the compaction story. Claude's is a row of its own above
                    // the root, because there the earlier turns are somewhere else entirely; here
                    // they are a few rows up, and all that is missing is the fact that the agent
                    // could no longer see them from this turn onwards.
                    if node?.compactedBefore == true {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.warn)
                            .frame(width: 20, height: 20)
                            .background(Theme.surfaceContainerHighest).clipShape(RoundedRectangle(cornerRadius: 6))
                            .help(L(.treeCompactedHelp))
                    }
                    if row.branchChildCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                            Text("\(row.branchChildCount + 1)").font(.fvLabelSmall).monospacedDigit()
                        }
                        .foregroundColor(Theme.onSurfaceVariant)
                        .padding(.horizontal, 6).frame(height: 20)
                        .background(Theme.surfaceContainerHighest).clipShape(RoundedRectangle(cornerRadius: 6))
                        .help(L(.treeBranchesHelp(row.branchChildCount + 1)))
                    }
                    // Regular weight on every row: a column that is all bold has no emphasis left.
                    promptText
                        .font(.fvBody)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(relativeTime)
                        .font(.fvLabelSmall).monospacedDigit().foregroundColor(Theme.onSurfaceVariant)
                        .layoutPriority(1)
                }
                if let n = node, !n.answerPreview.isEmpty {
                    answerText(n).font(.fvBodySmall).lineLimit(1)
                }
                if !chips.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(chips, id: \.name) { chip in
                            HStack(spacing: 5) {
                                StatusGlyph(status: chip.status, size: 11)
                                Text(L(.treeStoppedHere(chip.name))).font(.fvLabelSmall)
                                    .foregroundColor(Theme.onSurface)
                            }
                            .padding(.horizontal, 8).frame(height: 22)
                            .overlay(Capsule().strokeBorder(Theme.outlineVariant, lineWidth: 1))
                        }
                    }
                }
            }
            .padding(.trailing, 14).padding(.vertical, 8)
            .opacity(row.onActivePath ? 1 : 0.62)
        }
        .frame(minHeight: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(isSelected ? Theme.secondaryContainer : (hover ? Theme.surfaceContainerHigh : Color.clear))
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .background(GeometryReader { g in
            Color.clear.onChange(of: hover) { _, h in
                if h { model.focus.focusY = g.frame(in: .named("fleet")).midY }
            }
        })
        .onHover { h in
            hover = h
            if h { model.focus.hovered = row.nodeUuid }
            else if model.focus.hovered == row.nodeUuid { model.focus.hovered = nil }
        }
        .onTapGesture {
            model.selected = (model.selected == row.nodeUuid) ? nil : row.nodeUuid
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("fleet"))
                .onChanged { v in
                    guard let u = row.nodeUuid, let n = node else { return }
                    state.treeDragChanged(nodeUuid: u, nativeSid: n.nativeSessionId,
                                          prompt: n.text, location: v.location)
                }
                .onEnded { v in state.treeDragEnded(at: v.location) }
        )
        .help(node?.text ?? "")
    }

    /// Plain Text while idle — building an AttributedString for every visible row on every scroll
    /// tick is what made the list stutter. Rich text only appears once a search is on.
    @ViewBuilder private var promptText: some View {
        let preview = node?.preview ?? ""
        if model.searching {
            Text(treeHighlight(preview, query: model.query, base: Theme.onSurface))
        } else {
            Text(preview).foregroundColor(Theme.onSurface)
        }
    }

    @ViewBuilder private func answerText(_ n: TreeTurn) -> some View {
        let answerHit = model.searching && model.hits(n).answer
        let body = "↳ " + plainMarkdown(answerHit ? model.answerSnippet(n) : n.answerPreview)
        let tint = answerHit ? Theme.tertiary : Theme.onSurfaceVariant
        if model.searching {
            Text(treeHighlight(body, query: model.query, base: tint))
        } else {
            Text(body).foregroundColor(tint)
        }
    }

    private func hitBadge(_ label: String, _ color: Color) -> some View {
        Text(label)
            .font(.fvLabelSmall).foregroundColor(color)
            .padding(.horizontal, 6).frame(height: 20)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.5), lineWidth: 1))
    }

    private var relativeTime: String {
        guard let ts = node?.ts, let d = TreeTime.parse(ts) else { return "" }
        return RelativeTime.compact(d)
    }
}

// MARK: - Rail (lanes, curves, dots)

struct TreeRailView: View {
    let row: TreeRow
    let rowHeight: CGFloat
    let hasChips: Bool
    /// Newest-first flips the timeline: lanes that ran downward now run upward. Mirroring every
    /// y EXCEPT the dot keeps the dot on its text while the lines still point at the right rows.
    var flipped: Bool = false

    /// Dot sits at the vertical center of the text block (not of a chip-tall row).
    private var dotY: CGFloat { hasChips ? 27 : rowHeight / 2 }

    var body: some View {
        Canvas { ctx, size in
            let mainX = TreeLane.x(0)
            func Y(_ y: CGFloat) -> CGFloat { flipped ? size.height - y : y }
            // Pass-through ancestor lanes.
            for lane in row.passLanes {
                var p = Path()
                p.move(to: CGPoint(x: TreeLane.x(lane.depth), y: 0))
                p.addLine(to: CGPoint(x: TreeLane.x(lane.depth), y: size.height))
                ctx.stroke(p, with: .color(laneColor(lane.colorIndex).opacity(0.45)), lineWidth: 1.5)
            }
            // Main accent lane.
            if row.laneDepth == 0 {
                var p = Path()
                p.move(to: CGPoint(x: mainX, y: row.mainStartsHere ? dotY : Y(0)))
                p.addLine(to: CGPoint(x: mainX, y: row.mainEndsHere ? dotY : Y(size.height)))
                ctx.stroke(p, with: .color(Theme.accent), lineWidth: 2)
            } else if row.mainLanePasses {
                var p = Path()
                p.move(to: CGPoint(x: mainX, y: 0))
                p.addLine(to: CGPoint(x: mainX, y: size.height))
                ctx.stroke(p, with: .color(Theme.accent), lineWidth: 2)
            }
            // Side lane: connect curve on the branch's first row, then its own vertical.
            if row.laneDepth > 0 {
                let x = TreeLane.x(row.laneDepth)
                let color = laneColor(row.colorIndex)
                if row.isBranchFirst {
                    var c = Path()
                    c.move(to: CGPoint(x: TreeLane.x(row.laneDepth - 1), y: Y(0)))
                    c.addQuadCurve(to: CGPoint(x: x, y: dotY), control: CGPoint(x: x, y: Y(0)))
                    ctx.stroke(c, with: .color(color.opacity(0.7)), lineWidth: 1.5)
                } else {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: Y(0)))
                    p.addLine(to: CGPoint(x: x, y: dotY))
                    ctx.stroke(p, with: .color(color.opacity(0.7)), lineWidth: 1.5)
                }
                if !row.isBranchLast {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: dotY))
                    p.addLine(to: CGPoint(x: x, y: Y(size.height)))
                    ctx.stroke(p, with: .color(color.opacity(0.7)), lineWidth: 1.5)
                } else {
                    // dead end — short fade away from the dot, in whichever direction is "later"
                    let end = flipped ? max(dotY - 12, 0) : min(dotY + 12, size.height)
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: dotY))
                    p.addLine(to: CGPoint(x: x, y: end))
                    ctx.stroke(p, with: .linearGradient(
                        Gradient(colors: [color.opacity(0.6), .clear]),
                        startPoint: CGPoint(x: x, y: dotY), endPoint: CGPoint(x: x, y: end)),
                        lineWidth: 1.5)
                }
            }
            // The dot (node rows, and a versions row, which stands for nodes).
            var hasDot = false
            switch row.kind {
            case .node, .versions: hasDot = true
            default: break
            }
            if hasDot {
                let x = TreeLane.x(row.laneDepth)
                let color = row.laneDepth == 0 ? Theme.accent : laneColor(row.colorIndex)
                if row.laneDepth == 0 {
                    let r: CGFloat = row.isCurrentLeaf ? 5.5 : 4.5
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: dotY - r, width: r * 2, height: r * 2)),
                             with: .color(color))
                    // Where you are: a still ring around the node. It used to pulse, and nothing on
                    // screen moves unless you made it move.
                    if row.isCurrentLeaf {
                        let R: CGFloat = 9.5
                        ctx.stroke(Path(ellipseIn: CGRect(x: x - R, y: dotY - R, width: R * 2, height: R * 2)),
                                   with: .color(color.opacity(0.4)), lineWidth: 2)
                    }
                } else {
                    let r: CGFloat = 4
                    let rect = CGRect(x: x - r, y: dotY - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Theme.panel))
                    ctx.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.9)), lineWidth: 2)
                }
            }
        }
        // The lanes are drawn after body returns, where reading a Theme colour is not tracked; keying
        // the canvas on the seed is what redraws them in a new palette.
        .id(ThemeStore.shared.seed)
    }

    private func laneColor(_ idx: Int) -> Color { Theme.laneColor(idx) }
}

/// Paints every occurrence of `query` in a different colour so the match is findable inside a
/// long prompt or reply — a badge tells you WHERE it hit, this tells you WHAT hit.
func treeHighlight(_ text: String, query: String,
                   base: Color, hit: Color = Theme.amber) -> AttributedString {
    var a = AttributedString(text)
    a.foregroundColor = base
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return a }
    var from = text.startIndex
    while let r = text.range(of: q, options: .caseInsensitive, range: from ..< text.endIndex) {
        if let lo = AttributedString.Index(r.lowerBound, within: a),
           let hi = AttributedString.Index(r.upperBound, within: a) {
            a[lo ..< hi].foregroundColor = hit
            a[lo ..< hi].backgroundColor = hit.opacity(0.18)
            a[lo ..< hi].inlinePresentationIntent = .stronglyEmphasized
        }
        from = r.upperBound
        if from >= text.endIndex { break }
    }
    return a
}

// MARK: - Floating inspector (card + outside-click catcher)

/// Owns everything about the floating inspector and — crucially — observes the model itself, so
/// hovering a turn, pinning one, or the tree finishing its background load all re-render it.
struct TreeInspector: View {
    @ObservedObject var model: SessionTreeModel
    @ObservedObject var focus: TreeFocus
    let boardFrame: CGRect
    let dragging: Bool
    var onClosePanel: () -> Void

    var body: some View {
        if !dragging, boardFrame != .zero {
            let pinned = model.selected != nil
            let turn = model.detailNode(hovered: focus.hovered)
            let cardW: CGFloat = 380
            let cardH: CGFloat = pinned ? 470 : 190
            ZStack {
                // Everything left of the tree panel dismisses, one layer at a time: the expanded
                // card first, then the panel itself. The panel stays live throughout, so clicking
                // another turn switches to it rather than counting as an outside click.
                Color.black.opacity(0.001)
                    .frame(width: boardFrame.maxX, height: boardFrame.maxY)
                    .position(x: boardFrame.maxX / 2, y: boardFrame.maxY / 2)
                    .onTapGesture {
                        if model.selected != nil { model.selected = nil } else { onClosePanel() }
                    }
                if let turn {
                    TreeDetailCard(turn: turn, pinned: pinned, query: model.query,
                                   onUnpin: { model.selected = nil })
                        .position(x: max(boardFrame.minX + cardW / 2 + 8, boardFrame.maxX - cardW / 2 - 14),
                                  y: min(max(focus.focusY ?? boardFrame.midY, boardFrame.minY + cardH / 2 + 8),
                                         boardFrame.maxY - cardH / 2 - 8))
                        .animation(.easeOut(duration: 0.14), value: focus.focusY)
                        .animation(.easeOut(duration: 0.16), value: pinned)
                }
            }
        }
    }
}

// MARK: - Detail card

/// The node inspector: a frosted card that floats to the LEFT of the tree so it never covers it.
/// Hovering a turn shows a clipped preview; clicking one pins it and reveals the full prompt and
/// the full reply.
struct TreeDetailCard: View {
    @EnvironmentObject var state: AppState
    let turn: TreeTurn
    let pinned: Bool
    let query: String
    var onUnpin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if turn.nativeSessionId != nil {
                    Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundColor(Theme.primary)
                        .help(L(.treeNativeLeaf))
                }
                Text(absoluteTime(turn.ts)).font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                Spacer()
                if pinned {
                    Button(action: onUnpin) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.onSurfaceVariant)
                            .frame(width: 28, height: 28).contentShape(Circle())
                    }
                    .buttonStyle(.plain).help(L(.closeEsc))
                }
            }
            content
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 16)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(Theme.surfaceContainerHigh))
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
        // A hover preview must not eat clicks meant for the tree; a pinned card is interactive
        // so its text can be selected and scrolled.
        .allowsHitTesting(pinned)
        .transition(.opacity)
    }

    @ViewBuilder private var content: some View {
        if pinned {
            Text(markdownText(turn.text, query: query, base: Theme.onSurface))
                .font(.fvTitleSmall)
                .textSelection(.enabled)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !turn.answer.isEmpty {
                Divider().overlay(Theme.outlineVariant)
                ScrollView {
                    // Rendered, not shown raw: agents answer in Markdown, and the monospaced dump
                    // this replaces put `**` and backticks in front of every point that mattered.
                    Text(markdownText(turn.answer, query: query, base: Theme.onSurface))
                        .font(.fvBody)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
            }
            HStack {
                Spacer()
                Button {
                    state.forkOpenNode(nodeUuid: turn.uuid, nativeSid: turn.nativeSessionId,
                                       prompt: turn.text, joinClusterOf: nil)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 13))
                        Text(L(.treeOpenHere)).font(.fvLabel)
                    }
                    .foregroundColor(Theme.onSecondaryContainer)
                    .padding(.horizontal, 16).frame(height: 36)
                    .background(Theme.secondaryContainer).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L(.treeOpenHereHelp))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // The hover card shows excerpts, so it never lays out a multi-thousand-character
                // string that the reader isn't going to see.
                Text(treeHighlight(turn.preview, query: query, base: Theme.onSurface))
                    .font(.fvTitleSmall).lineLimit(4)
                if !turn.answerPreview.isEmpty {
                    Text(markdownText(turn.answerPreview, query: query, base: Theme.onSurfaceVariant))
                        .font(.fvBodySmall)
                        .lineLimit(5)
                }
            }
        }
    }

    private func absoluteTime(_ ts: String) -> String {
        guard let d = TreeTime.parse(ts) else { return "" }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

/// A one-line preview of Markdown, with the markers taken out rather than rendered: a row has no
/// room for formatting, and `**` in front of every second word was what it showed instead.
func plainMarkdown(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "**", with: "")
        .replacingOccurrences(of: "__", with: "")
        .replacingOccurrences(of: "`", with: "")
    while t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix(" ") { t.removeFirst() }
    return t
}

// MARK: - Time parsing

enum TreeTime {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parse(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }
}

/// Drag handle on the panel's left edge (mirror of SidebarDivider).
struct TreePanelDivider: View {
    @EnvironmentObject var state: AppState
    /// The width the panel is drawn at, and the most the window leaves room for.
    let width: Double
    let maxWidth: Double
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Theme.accent.opacity(0.6) : Theme.stroke)
            .frame(width: hovering ? 2 : 1)
            .overlay(
                Rectangle().fill(Color.clear).frame(width: 10).contentShape(Rectangle())
                    .onHover { h in
                        hovering = h
                        if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        // Window coordinates, as SidebarDivider and for the same reason: in its own
                        // the divider moves under the measurement and the width shakes.
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { v in
                                if startWidth == nil { startWidth = width }
                                let base = startWidth ?? width
                                state.treePanelWidth = min(maxWidth, max(380, base - v.translation.width))
                            }
                            .onEnded { _ in startWidth = nil; state.save() }
                    )
            )
    }
}
