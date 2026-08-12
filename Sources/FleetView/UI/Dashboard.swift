import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    /// Is a level-1 surface up, so the dashboard should recede? (See LayerConfig for the depths.)
    ///
    /// A drag whose target IS the dashboard does not recede at all: dropping a tree node or a
    /// search hit lands on the board or on a card, and neither is aimable through a wash.
    private var dashboardReceded: Bool {
        if state.treeDrag != nil { return false }
        return state.treePanelTerminalId != nil
            || state.searchOpen
            || state.draggingTerminalId != nil
    }

    /// A dragged card recedes the board but must not blur it. It used not to matter — a card's
    /// targets were the action dock and the tree edge, both drawn above the wash — but a card can
    /// now be dropped on another card, so the board is a target again and has to stay readable.
    private var dashboardBlurred: Bool { state.draggingTerminalId == nil }

    var body: some View {
        HStack(spacing: 0) {
            let receded = dashboardReceded
            HStack(spacing: 0) {
                Sidebar().frame(width: state.sidebarWidth)
                SidebarDivider()
                VStack(spacing: 0) {
                    DynamicPanel()      // agent-authored dynamic UI — tops the content column, beside the sidebar
                    TopBar()
                    Divider().overlay(Theme.stroke)
                    if state.peerStripVisible {
                        PeerStrip(fleet: state.peerFleet)
                        Divider().overlay(Theme.stroke)
                    }
                    // A peer's board replaces this Mac's rather than floating over it: the two look
                    // alike enough that anything less than taking the whole column would leave you
                    // unsure which fleet you are looking at — and these boards start terminals.
                    if let peer = state.peerSelected {
                        PeerWebBoard(peer: peer).id(peer.id)
                    } else {
                        MainArea()
                            .background(GeometryReader { g in     // the tree-drag drop area ("fleet" space)
                                Color.clear.preference(key: BoardFrameKey.self,
                                                       value: g.frame(in: .named("fleet")))
                            })
                    }
                }
            }
            .receded(receded, blurred: dashboardBlurred)
            if state.treePanelTerminalId != nil {
                TreePanelDivider()
                SessionTreePanel(model: state.treeModel)
                    .frame(width: state.treePanelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.22), value: state.treePanelTerminalId != nil)
        .background(Theme.bg)
        .frame(minWidth: 960, minHeight: 580)
        .overlay { treeInspector }     // interactive: text selection + scrolling
        .overlay { dragOverlay }
        .overlay { searchOverlay }
        .coordinateSpace(name: "fleet")
        .onPreferenceChange(BoardFrameKey.self) { state.boardFrame = $0 }
        .onPreferenceChange(CardFramesKey.self) { state.cardFrames = $0 }
        .onPreferenceChange(ClusterFramesKey.self) { state.clusterFrames = $0 }
        .sheet(item: $state.nameSheet) { req in
            NameSheet(request: req).environmentObject(state)
        }
        // ⌘F opens search; Tab widens its scope. The session tree binds ⌘F to its own node filter,
        // which is find-in-this-panel and the right meaning while you are in it — so ⌘F defers to it
        // and ⌘K stays the accelerator that always reaches search.
        .background {
            if state.treePanelTerminalId == nil {
                Button("") { state.toggleSearch() }
                    .keyboardShortcut("f", modifiers: .command).hidden()
            }
            Button("") { state.toggleSearch() }
                .keyboardShortcut("k", modifiers: .command).hidden()
        }
    }

    /// Search floats over the whole board rather than docking beside a terminal: a hit can come
    /// from any project, including one with nothing open.
    ///
    /// While a result is being dragged the panel gets out of the way — it covers the very board
    /// the node is being dropped onto. It stays mounted (opacity, not removal) because the drag
    /// gesture lives on the row and would be cancelled the moment the row disappeared.
    @ViewBuilder private var searchOverlay: some View {
        if state.searchOpen {
            let dragging = state.treeDrag?.hit != nil
            ZStack {
                // Catcher only — the dashboard's own recede supplies the dimming. A click on empty
                // space closes the deepest layer first: the preview (2) before the panel (1).
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if state.searchModel.preview != nil { state.searchModel.closePreview() }
                        else { state.closeSearch() }
                    }
                    .allowsHitTesting(!dragging)
                SearchPanel(model: state.searchModel).environmentObject(state)
                    .opacity(dragging ? 0.12 : 1)
                    .scaleEffect(dragging ? 0.97 : 1)
            }
            .animation(.easeOut(duration: 0.16), value: dragging)
            .transition(.opacity)
        }
    }

    /// The floating node inspector. It observes the tree model directly (see TreeInspector):
    /// AppState only holds it as a plain reference, so a card whose visibility was decided here
    /// would never react to hovering, pinning, or the tree finishing its load.
    @ViewBuilder private var treeInspector: some View {
        if state.treePanelTerminalId != nil {
            TreeInspector(model: state.treeModel,
                          focus: state.treeModel.focus,
                          boardFrame: state.boardFrame,
                          dragging: state.treeDrag != nil,
                          onClosePanel: { state.closeSessionTree() })
        }
    }

    /// What releasing here would do, in the words of the thing it would land on. Nil when nothing
    /// is under the cursor, so the chip never promises an outcome that isn't there.
    private var dropHint: String? {
        switch state.clusterDrop {
        case .cluster(let id):
            return "松开：加入「\(state.cluster(id)?.name ?? "cluster")」"
        case .card(let id):
            guard let t = state.terminals.first(where: { $0.id == id }) else { return nil }
            return "松开：与「\(t.name)」组成 cluster"
        case .leaveCluster:
            let name = state.terminals.first { $0.id == state.draggingTerminalId }?
                .clusterId.flatMap { state.cluster($0)?.name }
            return "松开：移出「\(name ?? "cluster")」"
        case nil:
            return nil
        }
    }

    /// One outline around something on the board, in "fleet" coordinates.
    ///
    /// Clipped to the board because every rect here is a laid-out frame, not a visible one: a card
    /// scrolled half under the top bar still reports its whole height, and a ring drawn across the
    /// header outlines nothing that is there.
    /// `alpha`/`fill`/`glow` are all read against `tint` at full strength — passing a pre-faded
    /// colour would multiply instead, and a 0.35 stroke with a 0.06 fill would quietly become 0.02.
    @ViewBuilder
    private func ring(_ rect: CGRect, radius: CGFloat, tint: Color, width: CGFloat,
                      alpha: Double = 1, dash: [CGFloat] = [],
                      fill: Double = 0, glow: Double = 0) -> some View {
        let f = rect.intersection(state.boardFrame)
        if !f.isNull, !f.isEmpty {
            RoundedRectangle(cornerRadius: radius)
                .fill(tint.opacity(fill))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .stroke(tint.opacity(alpha), style: StrokeStyle(lineWidth: width, dash: dash)))
                .shadow(color: tint.opacity(glow), radius: 12)
                .frame(width: f.width, height: f.height)
                .position(x: f.midX, y: f.midY)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var dragOverlay: some View {
        ZStack {
            if let dragId = state.draggingTerminalId {
                // No scrim of its own: the dashboard already receded (see dashboardReceded), and a
                // second wash on top of it also fell over the zones, which are the thing you are
                // aiming at.
                SessionTreeDropEdge(hot: state.hoveredTreeZone, frame: state.sessionTreeZoneFrame)
                // What is being landed on — a whole cluster box, or a single card. Drawn HERE, not
                // on the target itself, because the board lies under the dim wash and a highlight
                // that is dimmed along with everything else is not a highlight.
                //
                // Clipped to the board: a target scrolled half under the top bar still reports its
                // whole frame, and an accent ring drawn across the header highlights nothing.
                // Where the card came from, drawn first and drawn quietly: the loudest thing on the
                // board has to be what will happen, not what already is.
                if let c = state.dragSourceClusterFrame {
                    ring(c, radius: 14, tint: Theme.accent, width: 2, alpha: 0.35)
                }
                ForEach(Array(state.dragSourceCardFrames.enumerated()), id: \.offset) { _, r in
                    ring(r, radius: 12, tint: Theme.accent, width: 1.5, alpha: 0.5,
                         dash: [5, 4], fill: 0.06)
                }
                // …and what releasing here would do. Joining fills and glows; leaving is a dashed
                // amber outline — the colour the dock's Leave Cluster zone already uses, and
                // deliberately not the solid accent, because walking out of a task is the opposite
                // outcome and must not read as landing in one.
                if let target = state.clusterDropFrame {
                    ring(target.rect, radius: target.radius,
                         tint: target.leaving ? Theme.amber : Theme.accent, width: 2.5,
                         dash: target.leaving ? [7, 5] : [],
                         fill: target.leaving ? 0.05 : 0.16,
                         glow: target.leaving ? 0 : 0.5)
                }
                VStack { Spacer(); ActionDock(terminalId: dragId).environmentObject(state) }
                if let t = state.terminals.first(where: { $0.id == dragId }) {
                    DragPreviewChip(name: t.name, status: t.status, hint: dropHint)
                        .position(x: state.dragLocation.x, y: state.dragLocation.y - 16)
                }
            }
            if let d = state.treeDrag {
                // Board glow: release here → fork-open the node standalone.
                if state.treeBoardHot {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Theme.accent, lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.045)))
                        .frame(width: max(0, state.boardFrame.width - 14),
                               height: max(0, state.boardFrame.height - 14))
                        .position(x: state.boardFrame.midX, y: state.boardFrame.midY)
                }
                // The only hint is on the chip itself, and it names what THIS spot will do.
                TreeDragChip(prompt: d.prompt, action: state.treeDropCardId != nil ? .joinCluster
                                                     : (state.treeBoardHot ? .newTerminal : .none))
                    .position(x: d.location.x, y: d.location.y - 22)
            }
        }
        .allowsHitTesting(false)   // purely visual; the drag is driven by the card gesture
        .animation(.easeOut(duration: 0.16), value: state.draggingTerminalId)
        .animation(.easeOut(duration: 0.12), value: state.treeBoardHot)
        .animation(.spring(response: 0.24, dampingFraction: 0.75), value: state.clusterDrop)
        .onPreferenceChange(ZoneFrameKey.self) { state.setZoneFrames($0) }
    }

    static func pickFolder(into state: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        // Starting a project you haven't created yet is a normal thing to want, and the panel's own
        // New Folder button does it without FleetView inventing a second dialog for naming and
        // placing a directory — it is the same control every other Mac app offers here.
        panel.canCreateDirectories = true
        panel.prompt = "Open Project"
        panel.message = "Pick a folder for this project — or make a new one."
        if panel.runModal() == .OK { for url in panel.urls { state.addProject(path: url.path) } }
    }

    /// Make a folder and open it as a project. The open panel's own New Folder button does this too,
    /// but only for people who know it is there — starting a project from nothing is common enough
    /// to be worth a button of its own.
    static func newFolder(into state: AppState) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = "new-project"
        panel.prompt = "Create"
        panel.message = "Name the new project folder."
        // Where this user's projects actually live; the panel falls back to its own last location
        // when that folder is absent.
        let projectsHome = FV.home.appendingPathComponent("PycharmProjects")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: projectsHome.path, isDirectory: &isDir), isDir.boolValue {
            panel.directoryURL = projectsHome
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // `withIntermediateDirectories: true` also means "already exists is fine". The save
            // panel offers to replace an existing name, and that must never become deleting a
            // directory someone already has work in — it is opened as-is instead.
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            state.addProject(path: url.path)
        } catch {
            FV.log("new folder failed: \(url.path): \(error.localizedDescription)")
            NSAlert(error: error).runModal()
        }
    }
}

/// Board-wide actions that need an answer before they run.
///
/// Here rather than duplicated in the menu and the top bar: two copies of a confirmation are two
/// chances for one of them to understate what it is about to do.
@MainActor
enum BoardActions {
    /// Close every terminal. The cards survive, so this is recoverable and the caller's own UI
    /// (the top-bar panel) is confirmation enough; the menu item, which has no such panel, asks.
    static func confirmCloseAll(_ state: AppState, reason: String) {
        let open = state.openTerminalCount
        let a = NSAlert()
        a.messageText = open > 0 ? "关闭 \(open) 个终端？" : "关闭所有终端？"
        a.informativeText = "正在运行的 agent 会被停止。终端卡片会留在看板上——点击卡片可以重新打开并继续原来的会话。"
        a.addButton(withTitle: "关闭全部")
        a.addButton(withTitle: "取消")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        state.closeAllTerminals(reason: reason)
    }

    /// Empty the board. Always asks, from every entry point: this is the one action on the board
    /// that nothing can put back.
    static func confirmClear(_ state: AppState, reason: String) {
        let p = state.projects.count, t = state.terminals.count
        guard p > 0 || t > 0 else { return }
        let a = NSAlert()
        a.messageText = "清空看板？"
        // Says what goes and what stays. "This cannot be undone" alone leaves people guessing
        // whether their conversations are about to be deleted — they are not.
        a.informativeText = """
        \(p) 个项目和 \(t) 个终端会从 FleetView 移除，正在运行的 agent 会被停止。终端名称、mark 和 cluster 分组会一并丢失，无法撤销。

        对话历史不受影响：它们保存在 Claude / Codex 自己的记录里，⌘K 仍然可以搜索并打开。项目文件夹本身也不会被删除。
        """
        a.addButton(withTitle: "清空看板")
        a.addButton(withTitle: "取消")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        state.clearBoard(reason: reason)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var state: AppState
    @State private var showingClone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.3.group").foregroundColor(Theme.accent)
                Text("FleetView").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)

            // TASKS (collapsible)
            sectionHeader(title: "TASKS", count: state.tasks.count, collapsed: state.tasksCollapsed) {
                withAnimation(.easeOut(duration: 0.18)) { state.tasksCollapsed.toggle() }
                state.save()
            }
            if !state.tasksCollapsed {
                if state.taskGroups.isEmpty {
                    // "No terminals yet" is a lie when there are plenty and the filter is hiding them.
                    Text(state.showOnlyMarked && !state.terminals.isEmpty
                         ? "No marked terminals" : "No terminals yet")
                        .font(.system(size: 12)).foregroundColor(Theme.subtext.opacity(0.55))
                        .padding(.horizontal, 16).padding(.top, 6)
                    Spacer(minLength: 0)
                } else {
                    taskList
                }
            }

            Divider().overlay(Theme.stroke)

            // NOTES (collapsible) — sits above the footer; grows to fill when Tasks is collapsed.
            NotesSection(fill: state.tasksCollapsed)
            if state.tasksCollapsed && state.notesCollapsed { Spacer(minLength: 0) }

            Divider().overlay(Theme.stroke)
            // Three buttons share the sidebar's width, so the labels are one word each — at the
            // default 236pt "Open Folder" and "New Folder" side by side would both truncate.
            HStack(spacing: 0) {
                footerButton("Open", "folder", help: "Open an existing folder as a project") {
                    DashboardView.pickFolder(into: state)
                }
                Divider().frame(height: 20).overlay(Theme.stroke)
                footerButton("New", "folder.badge.plus", help: "Create a new folder and open it as a project") {
                    DashboardView.newFolder(into: state)
                }
                Divider().frame(height: 20).overlay(Theme.stroke)
                footerButton("Clone", "arrow.down.circle", help: "Clone a GitHub repository") {
                    showingClone = true
                }
            }
        }
        .background(Theme.panel)
        .sheet(isPresented: $showingClone) { CloneSheet().environmentObject(state) }
    }

    private var taskList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(state.taskGroups.enumerated()), id: \.element.id) { idx, group in
                    if idx > 0 {
                        DashedLine().padding(.horizontal, 12).padding(.vertical, 7)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill").font(.system(size: 8))
                            .foregroundColor(Theme.subtext.opacity(0.55))
                        Text(group.project.name.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Theme.subtext.opacity(0.6)).lineLimit(1)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 3)
                    ForEach(group.tasks) { task in TaskRow(task: task) }
                }
            }
            .padding(.horizontal, 8).padding(.top, 2)
        }
        .frame(maxHeight: .infinity)
    }

    /// A collapsible section header (chevron + title + count). Used for TASKS.
    private func sectionHeader(title: String, count: Int, collapsed: Bool,
                               toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(Theme.subtext)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.subtext)
                Spacer()
                Text("\(count)").font(.system(size: 11)).foregroundColor(Theme.subtext.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func footerButton(_ title: String, _ icon: String, help: String,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12)).foregroundColor(Theme.accent)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.text)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Draggable divider that resizes the sidebar (so long task titles can be revealed).
struct SidebarDivider: View {
    @EnvironmentObject var state: AppState
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Theme.accent.opacity(0.6) : Theme.stroke)
            .frame(width: hovering ? 2 : 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { h in
                        hovering = h
                        if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if startWidth == nil { startWidth = state.sidebarWidth }
                                let base = startWidth ?? state.sidebarWidth
                                state.sidebarWidth = min(520, max(180, base + v.translation.width))
                            }
                            .onEnded { _ in startWidth = nil; state.save() }
                    )
            )
    }
}

struct TaskRow: View {
    @EnvironmentObject var state: AppState
    let task: TaskItem
    @State private var hover = false

    private var terminal: TerminalSession? {
        if case .terminal(let id) = task { return state.terminals.first { $0.id == id } }
        return nil
    }
    private var cluster: Cluster? {
        if case .cluster(let id) = task { return state.clusters.first { $0.id == id } }
        return nil
    }
    private var isCluster: Bool { if case .cluster = task { return true }; return false }
    private var isSelected: Bool {
        if let t = terminal { return state.highlightedTerminalId == t.id }
        if let c = cluster  { return state.highlightedClusterId == c.id }
        return false
    }

    private var name: String { terminal?.name ?? cluster?.name ?? "" }
    private var status: TermStatus {
        if let t = terminal { return t.status }
        if let c = cluster { return state.clusterAggregateStatus(c.id) }
        return .closed
    }
    private var done: Bool {
        if let t = terminal { return t.subtaskDone }
        if let c = cluster { return state.clusterDone(c.id) }
        return false
    }
    private var subtitle: String {
        if terminal != nil { return "" }        // project is shown in the group header
        if let c = cluster {
            let n = state.members(ofCluster: c.id).count
            return "\(n) terminal\(n == 1 ? "" : "s")"
        }
        return ""
    }

    var body: some View {
        HStack(spacing: 9) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if isCluster {
                        Image(systemName: "circle.hexagongrid.fill").font(.system(size: 9)).foregroundColor(Theme.accent)
                    }
                    Text(name).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.text).lineLimit(1)
                    if done {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 10)).foregroundColor(Theme.green)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 10)).foregroundColor(Theme.subtext.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(status.taskLabel).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.statusColor(status))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isSelected ? Theme.accent.opacity(0.16) : (hover ? Theme.card : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { state.focusTask(task) }   // highlight + scroll, do not raise the window
        .help(name)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @State private var showWeb = false
    @State private var webQR: NSImage?
    @State private var showPower = false

    private var working: Int { state.terminals.filter { $0.status == .working }.count }
    private var needs: Int { state.terminals.filter { $0.status == .needsYou }.count }

    var body: some View {
        HStack(spacing: 9) {
            Text("\(state.projects.count) project\(state.projects.count == 1 ? "" : "s")")
                .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.text)
            Text("·").foregroundColor(Theme.subtext.opacity(0.6))
            Text("\(state.terminals.count) terminal\(state.terminals.count == 1 ? "" : "s")")
                .font(.system(size: 13)).foregroundColor(Theme.subtext)
            if working > 0 { pill("\(working) working", .working) }
            if needs > 0 { pill("\(needs) needs you", .needsYou) }
            Spacer()
            markFilterButton
            updateButton
            searchButton
            peersButton
            powerButton
            webButton
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.panel.opacity(0.55))
    }

    /// Shown only when a newer release exists. A pill rather than a dialog: an update is worth
    /// noticing, not worth interrupting a fleet of running agents for. Clicking opens the release
    /// page; the × means "not this version" and it will not come back until the next one.
    @ViewBuilder private var updateButton: some View {
        if let s = state.updates.status {
            // Mid-install: the alert is gone and this is the only place left to say so.
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
                Text(s).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.onAccent)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Theme.accent).clipShape(Capsule())
        } else if let r = state.updates.available {
            HStack(spacing: 5) {
                // Same alert the menu item shows — one offer, not two that can drift apart.
                Button { UpdateUI.present(.newer(r), updates: state.updates) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(r.version).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(Theme.onAccent)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .help("FleetView \(r.version) 已发布 — 点击安装")
                Button { state.updates.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundColor(Theme.onAccent.opacity(0.7))
                }
                .buttonStyle(.plain).padding(.trailing, 7)
                .help("忽略这个版本")
            }
            .background(Theme.accent).clipShape(Capsule())
        }
    }

    private var marked: Int { state.terminals.filter(\.subtaskDone).count }

    /// Show only marked terminals. Filled bookmark + a count while it is on, because a board that is
    /// hiding most of itself has to say so somewhere that is always visible — the alternative is
    /// wondering where your terminals went. It stays out of the way when nothing is marked at all.
    @ViewBuilder private var markFilterButton: some View {
        if marked > 0 || state.showOnlyMarked {
            Button { state.showOnlyMarked.toggle(); state.save() } label: {
                HStack(spacing: 5) {
                    Image(systemName: state.showOnlyMarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text(state.showOnlyMarked ? "\(marked) marked" : "\(marked)")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(state.showOnlyMarked ? Theme.onAccent : Theme.text)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(state.showOnlyMarked ? Theme.markTint : Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(state.showOnlyMarked ? Color.clear : Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(state.showOnlyMarked ? "显示全部终端" : "只显示被 Mark 的终端")
        }
    }

    /// The only on-screen way in to conversation search (⌘K also opens it). Icon-only, matching
    /// the Web button's chrome.
    private var searchButton: some View {
        Button { state.toggleSearch() } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(state.searchOpen ? Theme.accent : Theme.text)
                .frame(width: 24, height: 21)
                .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("搜索所有 Claude / Codex 对话历史 (⌘K)")
    }

    /// Stop the whole fleet. A popover rather than a bare button, because this is one click away
    /// from ending every running agent — the panel is the confirmation, and it is also where the
    /// "do this on quit too" setting lives, next to the thing it automates.
    private var powerButton: some View {
        let open = state.openTerminalCount
        return Button { showPower.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "power").font(.system(size: 11, weight: .semibold))
                if open > 0 {
                    Text("\(open)").font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundColor(showPower ? Theme.accent : Theme.text)
            .padding(.horizontal, open > 0 ? 8 : 0)
            .frame(minWidth: 24, minHeight: 21)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("关闭所有终端 / 退出时关闭")
        .popover(isPresented: $showPower, arrowEdge: .bottom) { powerPopover }
    }

    private var powerPopover: some View {
        let open = state.openTerminalCount
        return VStack(alignment: .leading, spacing: 12) {
            Text("关闭所有终端")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text)
            Text(open > 0 ? "\(open) 个终端正在运行。关闭会停止它们的 agent 进程（tmux 会话一并销毁）。"
                          : "当前没有打开的终端。仍会清理可能残留的 tmux 会话。")
                .font(.system(size: 11)).foregroundColor(Theme.subtext)
                .fixedSize(horizontal: false, vertical: true)
            // The one thing that makes this safe to press: nothing is lost from the board.
            Label("卡片会保留。点击卡片可重新打开并 resume 原来的 Claude / Codex 会话。",
                  systemImage: "arrow.uturn.backward")
                .font(.system(size: 10)).foregroundColor(Theme.subtext.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            if working > 0 {
                Label("\(working) 个 agent 正在工作中，会被打断。", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundColor(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                showPower = false
                state.closeAllTerminals(reason: "topbar")
            } label: {
                Text("关闭全部终端")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.onAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(Theme.red).clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            // Secondary by design: same panel, but text-only and behind its own alert. It sits
            // one click from the button above it and does something that button explicitly does
            // not — throw the board away.
            Button {
                showPower = false
                BoardActions.confirmClear(state, reason: "topbar")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash").font(.system(size: 10, weight: .semibold))
                    Text("清空所有项目并关闭所有终端").font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Theme.red)
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("移除全部项目与终端卡片（对话历史不受影响）")
            Divider().overlay(Theme.stroke)
            Toggle(isOn: Binding(get: { state.closeTerminalsOnQuit },
                                 set: { state.closeTerminalsOnQuit = $0; state.save() })) {
                Text("退出 FleetView 时关闭所有终端")
                    .font(.system(size: 12)).foregroundColor(Theme.text)
            }
            .toggleStyle(.checkbox)
            Text(state.closeTerminalsOnQuit
                 ? "退出即结束整个 fleet。"
                 : "默认关闭：退出后终端继续在后台运行，下次启动自动重新接上。")
                .font(.system(size: 10)).foregroundColor(Theme.subtext.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 260)
    }

    /// Opens the LAN switcher. The count appears once a scan has run — before that there is nothing
    /// honest to put there, and a "0" would read as "nobody is out there" rather than "not looked".
    private var peersButton: some View {
        let others = state.peerFleet.found.filter { !$0.isSelf }.count
        return Button { state.togglePeerStrip() } label: {
            HStack(spacing: 5) {
                Image(systemName: "network").font(.system(size: 11, weight: .semibold))
                if state.peerFleet.scanned && others > 0 {
                    Text("\(others)").font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundColor(state.peerStripVisible ? Theme.accent : Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Other FleetViews on this network")
    }

    private var webButton: some View {
        Button { showWeb.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe").font(.system(size: 11, weight: .semibold))
                Text("Web").font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(showWeb ? Theme.accent : Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Open this dashboard on another device")
        .popover(isPresented: $showWeb, arrowEdge: .bottom) { webPopover }
    }

    private var webPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FleetView on another device")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text)
            if let url = state.webDashboardURL {
                if let qr = webQR {
                    Image(nsImage: qr).interpolation(.none).resizable()
                        .frame(width: 176, height: 176)
                        .padding(8).background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Text("Scan on your phone, or open on any device on the same Wi-Fi. You'll see every terminal and can tap one to interact.")
                    .font(.system(size: 11)).foregroundColor(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(url).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        .foregroundColor(Theme.text)
                    Spacer(minLength: 4)
                    Button("Copy") { copyToClipboard(url) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Theme.accent)
                    Button("Open") { NSWorkspace.shared.open(URL(string: "http://localhost:\(state.web.port)/")!) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Theme.accent)
                }
                .padding(8).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 6))
                Label("LAN only — anyone on your network with this link can control your terminals.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundColor(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not on a network, or the server didn't start. Connect to Wi-Fi and reopen this.")
                    .font(.system(size: 11)).foregroundColor(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 250)
        .onAppear { webQR = state.webDashboardURL.flatMap { QRCode.image(for: $0) } }
    }

    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func pill(_ text: String, _ status: TermStatus) -> some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Theme.statusColor(status).opacity(0.18))
            .foregroundColor(Theme.statusColor(status))
            .clipShape(Capsule())
    }
}

// MARK: - Main area (all projects + terminals, always visible)

struct MainArea: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.projects.isEmpty {
            EmptyState(icon: "square.grid.2x2",
                       title: "Open a project to get started",
                       subtitle: "Every project can launch clean terminal windows for your agents.",
                       button: "Open Folder") { DashboardView.pickFolder(into: state) }
        } else if state.showOnlyMarked && state.visibleProjects.isEmpty {
            // The filter is on and nothing is marked. Offering the way out here matters: this screen
            // is otherwise indistinguishable from having lost every terminal.
            EmptyState(icon: "bookmark",
                       title: "No marked terminals",
                       subtitle: "The board is filtered to marked terminals only. Mark one from its card, or show everything again.",
                       button: "Show all terminals") { state.showOnlyMarked = false; state.save() }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        RunningStrip()
                        ForEach(state.visibleProjects) { p in
                            ProjectSection(project: p).id(p.id)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.scrollToId) { _, id in
                    if let id { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }
}

/// Everything that is working right now, lifted to the top of the board and out of its project.
///
/// The board is grouped by project because that is how work is organised; this answers the other
/// question — what is moving — which otherwise means scrolling every section to look for green
/// dots. The cards are the same cards, deliberately: this is a second place to see a terminal, not
/// a second kind of terminal, so it stays draggable, markable and openable like any other. Each one
/// carries the project it came from, because that is the one thing the grouping used to say and
/// this row cannot.
///
/// Absent, not empty, when nothing is running: a permanent "nothing is running" header is a line of
/// furniture that is wrong most of the time.
struct RunningStrip: View {
    @EnvironmentObject var state: AppState

    private var running: [TerminalSession] {
        state.visible(state.terminals.filter { $0.status == .working })
    }

    var body: some View {
        if !running.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11)).foregroundColor(Theme.statusColor(.working))
                    Text("RUNNING NOW")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.statusColor(.working))
                    Text("\(running.count)")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(Theme.subtext)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.card).clipShape(Capsule())
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 14)],
                          alignment: .leading, spacing: 14) {
                    ForEach(running) { t in
                        VStack(alignment: .leading, spacing: 5) {
                            projectTag(for: t)
                            TerminalCardView(terminal: t)
                        }
                    }
                }
            }
            .padding(14)
            .background(Theme.statusColor(.working).opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.statusColor(.working).opacity(0.22), lineWidth: 1))
        }
    }

    /// Where this card lives when it is not here. Double-click opens that folder, the same gesture
    /// the project header answers to — this label says "project" and so it should behave like one.
    ///
    /// lineLimit(1) for the same reason every other label on a card has it: a name that wraps
    /// changes the row's height, and this row is rebuilt every time an agent starts or stops.
    private func projectTag(for t: TerminalSession) -> some View {
        let name = state.projects.first { $0.id == t.projectId }?.name ?? "—"
        return HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 8)).foregroundColor(Theme.subtext.opacity(0.55))
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.subtext.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.leading, 2)
        // The whole tag, not just the text: it is two small glyphs and a 10pt label, and hitting
        // only the characters would be a worse target than the thing looks.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.openInFinder(t.projectId) }
        .help("双击在 Finder 中打开 \(name)")
    }
}

struct ProjectSection: View {
    @EnvironmentObject var state: AppState
    let project: Project

    // A cluster with no marked member is dropped whole rather than left as an empty frame.
    private var clusters: [Cluster] {
        state.clustersInProject(project.id).filter { !state.visible(state.members(ofCluster: $0.id)).isEmpty }
    }
    private var standalone: [TerminalSession] {
        state.visible(state.standaloneTerminals(inProject: project.id))
    }
    private var total: Int { state.terminals(inProject: project.id).count }
    private var newTokens: Int { state.projectNewTokens(project.id) }
    private var deltas: [TokenSample] { state.projectTokenDeltas(project.id) }
    private var lastTokenTime: Date? { state.projectLastTokenTime(project.id) }
    @State private var showChart = true
    @State private var copied = false
    @State private var gripHot = false
    /// A fixed point for the rate chip's 5s schedule. Held in @State so it survives the re-renders
    /// it would otherwise be reset by; the actual instant is irrelevant, only that it stops moving.
    @State private var rateEpoch = Date()
    // Scanned rather than observed: a skill is files on disk, with no event to subscribe to.
    //
    // Two levels, because they cost different amounts. `skillCount` is a directory listing and runs
    // for every project as its section appears — that is all the header needs. The SKILL.md bodies
    // are only read when the drawer is opened, which is also the moment a stale list would be
    // noticed, so the refresh and the laziness are the same act.
    @State private var skillCount = 0
    @State private var skills: [SkillInfo] = []
    @State private var showSkills = false
    @State private var pickedSkill: SkillInfo?

    private var collapsed: Bool { state.isCollapsed(project.id) }
    // Counted over every terminal in the project, not the filtered list: what the header reports
    // about hidden work has to be the truth about all of it.
    private var needsYou: Int { state.terminals(inProject: project.id).filter { $0.status == .needsYou }.count }
    private var working: Int { state.terminals(inProject: project.id).filter { $0.status == .working }.count }

    private func statusPill(_ text: String, _ status: TermStatus) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(Theme.statusColor(status).opacity(0.18))
            .foregroundColor(Theme.statusColor(status))
            .clipShape(Capsule())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            // Not gated on `collapsed`: folding a project puts its *terminals* away, and looking up
            // what a skill does is exactly the kind of thing you do without wanting the cards back.
            if showSkills { skillsPanel }
            // Folded: the header alone, which still carries the terminal count and the token
            // figures — a project you have put away should still be able to tell you it is busy.
            if !collapsed {
                if showChart && deltas.count > 1 {
                    ProjectTokenChart(samples: deltas, lastUpdated: lastTokenTime)
                }
                if total == 0 {
                    emptyRow
                } else {
                    ForEach(clusters) { c in ClusterContainer(clusterId: c.id).id(c.id) }
                    if !standalone.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 14)],
                                  alignment: .leading, spacing: 14) {
                            ForEach(standalone) { t in TerminalCardView(terminal: t).id(t.id) }
                        }
                    }
                }
            }
        }
        // The whole section is the drop target, not just its header: while you drag a project past
        // one with six cards open, the header is the smallest part of it you could be aiming at.
        .onDrop(of: [.text], delegate: ProjectReorderDrop(target: project.id, state: state))
        .onAppear { skillCount = ProjectSkills.count(projectPath: project.path) }
    }

    /// The skills drawer: names down the left, the picked one explained on the right.
    ///
    /// The absolute path is both selectable and copyable by button. Two ways to the same string
    /// because they answer different needs — dragging out part of a path to paste into a command,
    /// versus taking the whole thing without aiming.
    /// Eight rows, then scroll. A row is pinned to a fixed height rather than left to size itself:
    /// a ScrollView needs a definite height to stop at, and deriving that from a guess at the text's
    /// intrinsic size is how the ninth row ends up sliced in half along the bottom edge.
    private static let skillRowHeight: CGFloat = 24
    private static let skillRowGap: CGFloat = 1
    private static let skillsShown = 8

    private var skillsPanel: some View {
        let rows = min(skills.count, Self.skillsShown)
        let listHeight = CGFloat(rows) * Self.skillRowHeight
            + CGFloat(max(0, rows - 1)) * Self.skillRowGap
        return HStack(alignment: .top, spacing: 10) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Self.skillRowGap) {
                    ForEach(skills) { s in
                        let picked = (pickedSkill ?? skills.first)?.id == s.id
                        Button { pickedSkill = s } label: {
                            Text(s.name)
                                .font(.system(size: 12, weight: picked ? .semibold : .regular))
                                .foregroundColor(picked ? Theme.accent : Theme.text)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .frame(height: Self.skillRowHeight)
                                .background(picked ? Theme.accent.opacity(0.12) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 190, height: listHeight)
            Divider()
            if let s = pickedSkill ?? skills.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.name).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text)
                    Text(s.description.isEmpty ? "SKILL.md declares no description." : s.description)
                        .font(.system(size: 11)).foregroundColor(Theme.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(s.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.subtext.opacity(0.75))
                            .textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle)
                        Button { copyToClipboard(s.path) } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10))
                                .foregroundColor(Theme.subtext).padding(3)
                        }
                        .buttonStyle(.plain).help("Copy the absolute path")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(11)
        .background(Theme.card.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundColor(Theme.subtext.opacity(gripHot ? 0.95 : 0.35))
                .onHover { gripHot = $0 }
                .help("Drag to reorder projects")
                .onDrag {
                    // AppKit calls this on the main thread; the closure is simply not typed for it.
                    MainActor.assumeIsolated { state.draggingProjectId = project.id }
                    return NSItemProvider(object: project.id.uuidString as NSString)
                }
            // Same chevron idiom as the sidebar's section headers, pointing at the same thing.
            Button {
                withAnimation(.easeOut(duration: 0.18)) { state.toggleProjectCollapsed(project.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.subtext)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "展开这个项目" : "折叠这个项目")
            Image(systemName: "folder.fill").font(.system(size: 12)).foregroundColor(Theme.accent.opacity(0.9))
            // lineLimit(1) for the same reason the card's footer labels have it: the "+N/min" chip
            // below re-measures every 5s and swings between "+0/min" and "+1.2M/min", and on a
            // narrow content column that pushed this name onto a second line and back — moving the
            // whole project section, cards included, every five seconds.
            Text(project.name).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                .lineLimit(1)
                .onTapGesture(count: 2) { state.openInFinder(project.id) }
                .onTapGesture { copyToClipboard(project.name) }
                .help("Click to copy · double-click to open in Finder")
            Text("\(total)").font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Theme.card).foregroundColor(Theme.subtext).clipShape(Capsule())
            // Folded, the cards can no longer speak for themselves, and a terminal waiting on an
            // answer behind a closed section is the one thing this feature could genuinely cost
            // you. The header says it instead. RUNNING NOW already lifts working terminals out of
            // their section, so that half is belt-and-braces; "needs you" has no such rescue.
            if collapsed {
                if needsYou > 0 { statusPill("\(needsYou) needs you", .needsYou) }
                if working > 0 { statusPill("\(working) running", .working) }
            }
            // Both chips are pinned to one line at their intrinsic width. This row is width-critical
            // (see the name's lineLimit above) and these two were the only Texts in it still free to
            // wrap: squeezed, they took a second line, the header grew, and every card below it moved
            // — once every five seconds, as the rate chip re-measured. Squeezing has to fall on the
            // path, which is built to be truncated, not on figures that then change the row's height.
            if newTokens > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "sum").font(.system(size: 9, weight: .bold))
                    Text(TokenUsage.short(newTokens)).font(.system(size: 11, weight: .medium))
                }
                .lineLimit(1).fixedSize()
                .foregroundColor(Theme.accent)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Theme.accent.opacity(0.12)).clipShape(Capsule())
                .help("\(newTokens) new tokens used (input + output, excluding cache reads)")
            }
            if newTokens > 0 {
                // Anchored on a date this view keeps, never on `.now` — the same mistake the card's
                // run clock documents: `.now` is re-evaluated on every body pass, so each of the
                // board's many re-renders handed this a brand-new schedule and restarted its tick.
                TimelineView(.periodic(from: rateEpoch, by: 5)) { context in
                    let recent = state.projectTokensRecent(project.id, now: context.date)
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill").font(.system(size: 8))
                        Text("+\(TokenUsage.short(recent))/min").font(.system(size: 10, weight: .medium))
                            // Digits of the same width, so the chip stops resizing every time the
                            // rate crosses a digit — the horizontal half of the same twitch.
                            .monospacedDigit()
                    }
                    .lineLimit(1).fixedSize()
                    .foregroundColor(recent > 0 ? Theme.green : Theme.subtext)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background((recent > 0 ? Theme.green : Theme.subtext).opacity(0.14)).clipShape(Capsule())
                    .help("New tokens added in the last minute")
                }
            }
            Text(project.path).font(.system(size: 11)).foregroundColor(Theme.subtext.opacity(0.6))
                .lineLimit(1).truncationMode(.middle)
                .onTapGesture(count: 2) { state.openInFinder(project.id) }
                .onTapGesture { copyToClipboard(project.path) }
                .help("Click to copy · double-click to open in Finder")
            if copied {
                Text("Copied").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.green).clipShape(Capsule()).transition(.opacity)
            }
            Spacer(minLength: 10)
            // Hidden when the project carries none: a control that opens an empty drawer on most
            // projects is noise on every header it appears in.
            if skillCount > 0 {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { showSkills.toggle() }
                    if showSkills {
                        skills = ProjectSkills.scan(projectPath: project.path)
                        skillCount = skills.count
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "wand.and.stars").font(.system(size: 11))
                        Text("\(skillCount)").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(showSkills ? Theme.accent : Theme.subtext).padding(5)
                }
                .buttonStyle(.plain)
                .help(showSkills ? "Hide this project's skills"
                                 : "\(skillCount) skills in .claude/skills")
            }
            if deltas.count > 1 {
                Button { withAnimation(.easeOut(duration: 0.18)) { showChart.toggle() } } label: {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 12))
                        .foregroundColor(showChart ? Theme.accent : Theme.subtext).padding(5)
                }
                .buttonStyle(.plain).help(showChart ? "Hide token chart" : "Show token chart")
            }
            Button { state.openInFinder(project.id) } label: {
                Image(systemName: "folder").font(.system(size: 12)).foregroundColor(Theme.subtext).padding(5)
            }
            .buttonStyle(.plain).help("Reveal project in Finder")
            Button { state.requestNewTerminal(projectId: project.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    Text("Terminal").font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button { state.removeProject(project.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(Theme.subtext).padding(5)
            }
            .buttonStyle(.plain).help("Remove project from FleetView")
        }
    }

    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }

    private var emptyRow: some View {
        Button { state.requestNewTerminal(projectId: project.id) } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus.rectangle.on.rectangle").font(.system(size: 12))
                Text("New terminal").font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(Theme.subtext)
            .padding(.horizontal, 14).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundColor(Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

/// Drag-to-reorder for the board's project sections.
///
/// The move happens on `dropEntered` — the board rearranges live under the cursor — rather than on
/// release. A section is as tall as the terminals it holds, so an insertion line drawn at its edge
/// would frequently be scrolled out of view; seeing the sections themselves swap is the feedback.
///
/// SwiftUI hands these callbacks to a plain (nonisolated) struct even though it only ever calls
/// them on the main thread, hence `assumeIsolated` rather than a hop, which would reorder after
/// the drag has already moved on.
struct ProjectReorderDrop: DropDelegate {
    let target: UUID
    let state: AppState

    /// Only our own drags reorder: without the id check, any text dragged in from another app
    /// would shuffle the board.
    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { state.draggingProjectId != nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragged = state.draggingProjectId else { return }
            withAnimation(.easeInOut(duration: 0.18)) { state.moveProject(dragged, onto: target) }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { state.draggingProjectId = nil }
        return true      // the order was already committed (and saved) on the way in
    }
}

// MARK: - Cluster container (a task served by multiple terminals)

struct ClusterContainer: View {
    @EnvironmentObject var state: AppState
    let clusterId: UUID

    private var name: String { state.cluster(clusterId)?.name ?? "" }
    private var allMembers: [TerminalSession] { state.members(ofCluster: clusterId) }
    private var members: [TerminalSession] { state.visible(allMembers) }
    private var highlighted: Bool { state.highlightedClusterId == clusterId }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 12)).foregroundColor(Theme.accent)
                Text("CLUSTER").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.accent.opacity(0.85))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.14)).clipShape(Capsule())
                Text(name)
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.text).lineLimit(1)
                    .onTapGesture(count: 2) { state.requestRenameCluster(clusterId) }
                    .help(name)
                Button { state.requestRenameCluster(clusterId) } label: {
                    Image(systemName: "pencil").font(.system(size: 10)).foregroundColor(Theme.subtext)
                }
                .buttonStyle(.plain).help("Rename cluster task")
                // The cluster's real size, with what the filter is showing of it — the header must
                // not claim a two-terminal task when the task has six.
                Text(members.count == allMembers.count
                     ? "· \(allMembers.count) terminal\(allMembers.count == 1 ? "" : "s")"
                     : "· \(members.count) of \(allMembers.count) shown")
                    .font(.system(size: 11)).foregroundColor(Theme.subtext)
                Spacer()
                Button { state.addToCluster(clusterId) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("Agent").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).help("Add another agent to this task")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 460), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(members) { t in TerminalCardView(terminal: t) }
            }
        }
        .padding(14)
        .background(Theme.accent.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(highlighted ? Theme.accent : Theme.accent.opacity(0.28), lineWidth: highlighted ? 2 : 1))
        .shadow(color: highlighted ? Theme.accent.opacity(0.35) : .clear, radius: highlighted ? 10 : 0)
        .animation(.easeOut(duration: 0.2), value: highlighted)
        // The whole box is a drop target for a dragged card — the task is the thing you are aiming
        // at, not whichever member card happens to be under the cursor.
        .background(GeometryReader { g in
            Color.clear.preference(key: ClusterFramesKey.self,
                                   value: [clusterId: [g.frame(in: .named("fleet"))]])
        })
    }
}

// MARK: - Empty state

struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon).font(.system(size: 42, weight: .light)).foregroundColor(Theme.subtext.opacity(0.7))
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.text)
            Text(subtitle).font(.system(size: 13)).foregroundColor(Theme.subtext)
            Button(action: action) {
                Text(button).font(.system(size: 13, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 8)
            }
            .buttonStyle(.plain).foregroundColor(.white)
            .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

// MARK: - Session-tree drag plumbing

/// The fleet board's frame in the "fleet" space — the standalone drop target for tree nodes.
struct BoardFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

/// Every terminal card's frame — same-project cards double as drop targets, both for a tree node
/// and for another card being dragged onto them.
///
/// A *list* of frames per terminal, because one terminal can be on screen twice: a running card is
/// drawn in the RUNNING NOW strip and again in its own project section. Keyed to a single rect the
/// two overwrote each other, so whichever the reduce saw last was the only one you could drop on —
/// and the strip, being the first thing at the top of the board, was the one that lost.
struct CardFramesKey: PreferenceKey {
    static var defaultValue: [UUID: [CGRect]] = [:]
    static func reduce(value: inout [UUID: [CGRect]], nextValue: () -> [UUID: [CGRect]]) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

/// Every cluster container's frame. A dragged card landing anywhere inside one joins that task, so
/// the box — not its member cards — is what lights up and what the drop resolves against.
struct ClusterFramesKey: PreferenceKey {
    static var defaultValue: [UUID: [CGRect]] = [:]
    static func reduce(value: inout [UUID: [CGRect]], nextValue: () -> [UUID: [CGRect]]) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

/// The right edge turns into a drop target while a card is dragged — release there to open that
/// terminal's session tree, on the side the panel itself comes from.
struct SessionTreeDropEdge: View {
    let hot: Bool
    let frame: CGRect

    var body: some View {
        if frame != .zero {
            VStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(hot ? .white : Theme.accent)
                Text("会话树")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(hot ? .white : Theme.accent.opacity(0.9))
            }
            .frame(width: frame.width, height: frame.height)
            .background(
                LinearGradient(colors: [Theme.accent.opacity(hot ? 0.42 : 0.13), .clear],
                               startPoint: .trailing, endPoint: .leading)
            )
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.accent.opacity(hot ? 1 : 0.5)).frame(width: hot ? 3 : 1.5)
            }
            .position(x: frame.midX, y: frame.midY)
            .animation(.easeOut(duration: 0.12), value: hot)
        }
    }
}

/// The chip that follows the cursor while dragging a tree node. Its second line is the whole
/// hint system: it names what releasing HERE will do, and says nothing when there's no target.
struct TreeDragChip: View {
    enum Action { case none, newTerminal, joinCluster
        var label: String? {
            switch self {
            case .none:        return nil
            case .newTerminal: return "松开：以此节点开新终端"
            case .joinCluster: return "松开：开新终端并加入该 cluster"
            }
        }
    }
    let prompt: String
    let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(Theme.accent)
                Text(prompt.replacingOccurrences(of: "\n", with: " ").prefix(24))
                    .font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.text)
                    .lineLimit(1)
            }
            if let label = action.label {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(action.label == nil ? Theme.stroke : Theme.accent, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
        .animation(.easeOut(duration: 0.1), value: action.label)
    }
}
