import SwiftUI
import AppKit

/// The right-hand "会话树" panel: a GitUp-style vertical lane graph of one Claude session's
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
                    if row.branchChildCount > 0 {
                        Text("⑂ \(row.branchChildCount + 1)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.14)).clipShape(Capsule())
                    }
                    Text(promptLine)
                        .font(.system(size: 12.5, weight: row.onActivePath ? .medium : .regular))
                        .foregroundColor(Theme.text)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(relativeTime)
                        .font(.system(size: 10)).foregroundColor(Theme.subtext.opacity(0.8))
                        .layoutPriority(1)
                }
                if let n = node, !n.answer.isEmpty {
                    let answerHit = model.searching && model.hits(n).answer
                    Text("↳ " + (answerHit ? model.answerSnippet(n)
                                           : n.answer.replacingOccurrences(of: "\n", with: " ")))
                        .font(.system(size: 11))
                        .foregroundColor(answerHit ? Theme.lanePalette[0].opacity(0.95)
                                                   : Theme.subtext.opacity(0.75))
                        .lineLimit(1)
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
                if h { model.focusY = g.frame(in: .named("fleet")).midY }
            }
        })
        .onHover { h in
            hover = h
            if h { model.hovered = row.nodeUuid } else if model.hovered == row.nodeUuid { model.hovered = nil }
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

    private func hitBadge(_ label: String, _ color: Color) -> some View {
        Text(label)
            .font(.system(size: 8.5, weight: .bold)).foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15)).clipShape(Capsule())
    }

    private var promptLine: String {
        (node?.text ?? "").replacingOccurrences(of: "\n", with: " ")
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

// MARK: - Floating inspector (card + outside-click catcher)

/// Owns everything about the floating inspector and — crucially — observes the model itself, so
/// hovering a turn, pinning one, or the tree finishing its background load all re-render it.
struct TreeInspector: View {
    @ObservedObject var model: SessionTreeModel
    let boardFrame: CGRect
    let dragging: Bool
    var onClosePanel: () -> Void

    var body: some View {
        if !dragging, boardFrame != .zero {
            let pinned = model.selected != nil
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
                if model.detailNode != nil {
                    TreeDetailCard(model: model)
                        .position(x: max(boardFrame.minX + cardW / 2 + 8, boardFrame.maxX - cardW / 2 - 14),
                                  y: min(max(model.focusY ?? boardFrame.midY, boardFrame.minY + cardH / 2 + 8),
                                         boardFrame.maxY - cardH / 2 - 8))
                        .animation(.easeOut(duration: 0.14), value: model.focusY)
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
    @ObservedObject var model: SessionTreeModel

    private var pinned: Bool { model.selected != nil }
    private var turn: TreeTurn? { model.detailNode }

    var body: some View {
        if let turn {
            VStack(alignment: .leading, spacing: 9) {
                header(turn)
                content(turn)
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
    }

    private func header(_ turn: TreeTurn) -> some View {
        HStack(spacing: 6) {
            if turn.nativeSessionId != nil {
                Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundColor(Theme.green)
                    .help("已有会话的 leaf 正好在此 — fork 无需写文件")
            }
            Text(absoluteTime(turn.ts)).font(.system(size: 9.5)).foregroundColor(Theme.subtext)
            Spacer()
        }
    }

    @ViewBuilder private func content(_ turn: TreeTurn) -> some View {
        if pinned {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(turn.text).font(.system(size: 12)).foregroundColor(Theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !turn.answer.isEmpty {
                        Divider().overlay(Theme.stroke)
                        Text(turn.answer)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.subtext)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 420)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Text(turn.text).font(.system(size: 12)).foregroundColor(Theme.text)
                    .lineLimit(4)
                if !turn.answer.isEmpty {
                    Text(turn.answer)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.subtext)
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
