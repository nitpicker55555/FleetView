import SwiftUI
import AppKit

/// The right-hand "会话树" panel: a GitUp-style vertical lane graph of one agent session's
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
    private func idChip(label: String, value: String, copied: Binding<Bool>, tint: Color) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation(.easeOut(duration: 0.12)) { copied.wrappedValue = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation { copied.wrappedValue = false }
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 0) {
                    Text(label).font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Theme.subtext.opacity(0.8)).lineLimit(1)
                    Text(copied.wrappedValue ? "copied" : String(value.prefix(8)))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(copied.wrappedValue ? Theme.green : Theme.text)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain).help("点击复制完整 id")
    }

    private var boundTerminal: TerminalSession? {
        state.terminals.first { $0.id == state.treePanelTerminalId }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
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
        .onExitCommand { state.closeSessionTree() }              // Esc closes the panel
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.accent)
                Text("会话树").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.text)
                if let sid = model.boundSessionId {
                    idChip(label: "session", value: sid, copied: $copiedSid, tint: Theme.subtext)
                }
                if let t = boundTerminal {
                    idChip(label: t.name, value: t.id.uuidString.lowercased(),
                           copied: $copiedTid, tint: Theme.statusColor(t.status))
                }
                Spacer()
                Button { state.closeSessionTree() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.subtext)
                }
                .buttonStyle(.plain).help("关闭 (Esc)")
            }
            if model.emptyReason == nil {
                HStack(spacing: 6) {
                    Text("⑂ \(model.tree.branchPoints) · \(model.tree.nodeCount) 节点")
                        .font(.system(size: 10)).foregroundColor(Theme.subtext)
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10))
                .foregroundColor(Theme.subtext.opacity(0.8))
            TextField("搜索 prompt 与回复", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(Theme.text)
                .focused($searchFocused)
                .onExitCommand { model.query = "" }
            if !model.query.isEmpty {
                Text("\(model.rows.count)").font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.subtext)
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        .foregroundColor(Theme.subtext.opacity(0.7))
                }.buttonStyle(.plain)
            }
            Button { model.searchAnswers.toggle() } label: {
                Text("含回复")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(model.searchAnswers ? Theme.accent : Theme.subtext.opacity(0.7))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(model.searchAnswers ? Theme.accent.opacity(0.15) : Color.clear)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain).help("搜索范围是否包含 agent 回复")
            Button { model.newestFirst.toggle() } label: {
                Image(systemName: model.newestFirst ? "arrow.down" : "arrow.up")
                    .font(.system(size: 9.5, weight: .bold)).foregroundColor(Theme.subtext)
            }
            .buttonStyle(.plain)
            .help(model.newestFirst ? "最新在上 — 点击改为最早在上" : "最早在上 — 点击改为最新在上")
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Theme.card.opacity(searchFocused ? 0.95 : 0.45))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(searchFocused ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1))
        .padding(.horizontal, 12).padding(.vertical, 8)
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
            Text(reason).font(.system(size: 12)).foregroundColor(Theme.subtext)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.regular)
            Text("正在解析会话树…").font(.system(size: 12)).foregroundColor(Theme.subtext)
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
                Text("⋯ \(count) turns")
                    .font(.system(size: 10.5)).foregroundColor(Theme.subtext)
                    .padding(.horizontal, 11).padding(.vertical, 3)
                    .background(Theme.card).clipShape(Capsule())
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain).help("展开被折叠的 \(count) 个节点")
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
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                        Text("展开压缩前的 \(turns) 轮对话")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.12)).clipShape(Capsule())
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("下面这段是从一次上下文压缩之后继续的 —— 展开压缩前的 \(turns) 轮对话")
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "clock.badge.xmark")
                        .font(.system(size: 9, weight: .bold))
                    Text("压缩前的对话已不在这个项目里")
                        .font(.system(size: 10.5))
                }
                .foregroundColor(Theme.subtext.opacity(0.8))
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(Theme.card).clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .help("这段对话继续自一个已经不在 ~/.claude/projects 里的会话文件")
            }
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
                        if h.answer { hitBadge("回复", Theme.lanePalette[0]) }
                    }
                    // Codex's half of the compaction story. Claude's is a row of its own above
                    // the root, because there the earlier turns are somewhere else entirely; here
                    // they are a few rows up, and all that is missing is the fact that the agent
                    // could no longer see them from this turn onwards.
                    if node?.compactedBefore == true {
                        Text("⇠ 已压缩")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.amber)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.amber.opacity(0.14)).clipShape(Capsule())
                            .help("上下文在这一轮之前被压缩过 —— 更早的对话还在树上，但从这里开始 agent 看不到它们了")
                    }
                    if row.branchChildCount > 0 {
                        Text("⑂ \(row.branchChildCount + 1)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.14)).clipShape(Capsule())
                    }
                    promptText
                        .font(.system(size: 12.5, weight: row.onActivePath ? .medium : .regular))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(relativeTime)
                        .font(.system(size: 10)).foregroundColor(Theme.subtext.opacity(0.8))
                        .layoutPriority(1)
                }
                if let n = node, !n.answerPreview.isEmpty {
                    answerText(n).font(.system(size: 11)).lineLimit(1)
                }
                if !chips.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(chips, id: \.name) { chip in
                            HStack(spacing: 4) {
                                Circle().fill(Theme.statusColor(chip.status)).frame(width: 6, height: 6)
                                Text("\(chip.name) 停在这里").font(.system(size: 9.5, weight: .semibold))
                                    .foregroundColor(Theme.text)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.card).clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                        }
                    }
                }
            }
            .padding(.trailing, 12).padding(.vertical, 8)
            .opacity(row.onActivePath ? 1 : 0.62)
        }
        .frame(minHeight: rowHeight)
        .background(isSelected ? Theme.card : (hover ? Theme.cardHover.opacity(0.55) : Color.clear))
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Theme.accent).frame(width: 2) }
        }
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
            Text(treeHighlight(preview, query: model.query, base: Theme.text))
        } else {
            Text(preview).foregroundColor(Theme.text)
        }
    }

    @ViewBuilder private func answerText(_ n: TreeTurn) -> some View {
        let answerHit = model.searching && model.hits(n).answer
        let body = "↳ " + (answerHit ? model.answerSnippet(n) : n.answerPreview)
        let tint = answerHit ? Theme.lanePalette[0].opacity(0.95) : Theme.subtext.opacity(0.75)
        if model.searching {
            Text(treeHighlight(body, query: model.query, base: tint))
        } else {
            Text(body).foregroundColor(tint)
        }
    }

    private func hitBadge(_ label: String, _ color: Color) -> some View {
        Text(label)
            .font(.system(size: 8.5, weight: .bold)).foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15)).clipShape(Capsule())
    }

    private var relativeTime: String {
        guard let ts = node?.ts, let d = TreeTime.parse(ts) else { return "" }
        return RelativeTime.short(d) ?? ""
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
            // The dot (only node rows draw one).
            if case .node = row.kind {
                let x = TreeLane.x(row.laneDepth)
                let color = row.laneDepth == 0 ? Theme.accent : laneColor(row.colorIndex)
                if row.laneDepth == 0 {
                    let r: CGFloat = row.isCurrentLeaf ? 5.5 : 4.5
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: dotY - r, width: r * 2, height: r * 2)),
                             with: .color(color))
                } else {
                    let r: CGFloat = 4
                    let rect = CGRect(x: x - r, y: dotY - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Theme.panel))
                    ctx.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.9)), lineWidth: 2)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if row.isCurrentLeaf { LeafPulse().offset(x: TreeLane.x(0) - 9, y: dotY - 9) }
        }
    }

    private func laneColor(_ idx: Int) -> Color { Theme.laneColor(idx) }
}

/// The current-leaf pulse ring (same animation language as StatusDot).
struct LeafPulse: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .stroke(Theme.accent.opacity(0.5), lineWidth: 2)
            .frame(width: 18, height: 18)
            .scaleEffect(pulse ? 1.15 : 0.5)
            .opacity(pulse ? 0 : 0.8)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
            .allowsHitTesting(false)
    }
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
    let turn: TreeTurn
    let pinned: Bool
    let query: String
    var onUnpin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                if turn.nativeSessionId != nil {
                    Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundColor(Theme.green)
                        .help("已有会话的 leaf 正好在此 — fork 无需写文件")
                }
                Text(absoluteTime(turn.ts)).font(.system(size: 9.5)).foregroundColor(Theme.subtext)
                Spacer()
            }
            content
        }
        .padding(13)
        .frame(width: 380, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(Theme.panel)
                .overlay(                       // one soft top highlight = "lifted", not blurred
                    RoundedRectangle(cornerRadius: 13).fill(
                        LinearGradient(colors: [Color.white.opacity(0.055), .clear],
                                       startPoint: .top, endPoint: .bottom))
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 13)
            .stroke(pinned ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 26, y: 12)
        // A hover preview must not eat clicks meant for the tree; a pinned card is interactive
        // so its text can be selected and scrolled.
        .allowsHitTesting(pinned)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    @ViewBuilder private var content: some View {
        if pinned {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(treeHighlight(turn.text, query: query, base: Theme.text))
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !turn.answer.isEmpty {
                        Divider().overlay(Theme.stroke)
                        Text(treeHighlight(turn.answer, query: query, base: Theme.subtext))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 420)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                // The hover card shows excerpts, so it never lays out a multi-thousand-character
                // string that the reader isn't going to see.
                Text(treeHighlight(turn.preview, query: query, base: Theme.text))
                    .font(.system(size: 12)).lineLimit(4)
                if !turn.answerPreview.isEmpty {
                    Text(treeHighlight(turn.answerPreview, query: query, base: Theme.subtext))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(5)
                }
                Text("点击该节点查看完整内容 · 拖动它可开新终端")
                    .font(.system(size: 9.5)).foregroundColor(Theme.subtext.opacity(0.7))
                    .padding(.top, 1)
            }
        }
    }

    private func absoluteTime(_ ts: String) -> String {
        guard let d = TreeTime.parse(ts) else { return "" }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
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
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if startWidth == nil { startWidth = state.treePanelWidth }
                                let base = startWidth ?? state.treePanelWidth
                                state.treePanelWidth = min(720, max(380, base - v.translation.width))
                            }
                            .onEnded { _ in startWidth = nil; state.save() }
                    )
            )
    }
}
