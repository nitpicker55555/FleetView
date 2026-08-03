import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    /// Is a level-1 surface up, so the dashboard should recede? (See LayerConfig for the depths.)
    ///
    /// The exception is a drag whose target IS the dashboard: dropping a tree node or a search hit
    /// lands on the board or on a card, and you cannot aim at something blurred. A terminal drag is
    /// not an exception — its targets are the action zones and the tree edge, never the board — and
    /// that is the case this used to get wrong, dimming the zones along with everything else and
    /// never blurring the board at all.
    private var dashboardReceded: Bool {
        if state.treeDrag != nil { return false }
        return state.treePanelTerminalId != nil
            || state.searchOpen
            || state.draggingTerminalId != nil
    }

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
                    MainArea()
                        .background(GeometryReader { g in     // the tree-drag drop area ("fleet" space)
                            Color.clear.preference(key: BoardFrameKey.self,
                                                   value: g.frame(in: .named("fleet")))
                        })
                }
            }
            .receded(receded)
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

    @ViewBuilder private var dragOverlay: some View {
        ZStack {
            if let dragId = state.draggingTerminalId {
                // No scrim of its own: the dashboard already receded (see dashboardReceded), and a
                // second wash on top of it also fell over the zones, which are the thing you are
                // aiming at.
                SessionTreeDropEdge(hot: state.hoveredTreeZone, frame: state.sessionTreeZoneFrame)
                VStack { Spacer(); ActionDock(terminalId: dragId).environmentObject(state) }
                if let t = state.terminals.first(where: { $0.id == dragId }) {
                    DragPreviewChip(name: t.name, status: t.status)
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
                    Text("No terminals yet")
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
            updateButton
            searchButton
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
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(state.projects) { p in
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

struct ProjectSection: View {
    @EnvironmentObject var state: AppState
    let project: Project

    private var clusters: [Cluster] { state.clustersInProject(project.id) }
    private var standalone: [TerminalSession] { state.standaloneTerminals(inProject: project.id) }
    private var total: Int { state.terminals(inProject: project.id).count }
    private var newTokens: Int { state.projectNewTokens(project.id) }
    private var deltas: [TokenSample] { state.projectTokenDeltas(project.id) }
    private var lastTokenTime: Date? { state.projectLastTokenTime(project.id) }
    @State private var showChart = true
    @State private var copied = false
    @State private var gripHot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
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
        // The whole section is the drop target, not just its header: while you drag a project past
        // one with six cards open, the header is the smallest part of it you could be aiming at.
        .onDrop(of: [.text], delegate: ProjectReorderDrop(target: project.id, state: state))
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
            if newTokens > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "sum").font(.system(size: 9, weight: .bold))
                    Text(TokenUsage.short(newTokens)).font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Theme.accent)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Theme.accent.opacity(0.12)).clipShape(Capsule())
                .help("\(newTokens) new tokens used (input + output, excluding cache reads)")
            }
            if newTokens > 0 {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    let recent = state.projectTokensRecent(project.id, now: context.date)
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill").font(.system(size: 8))
                        Text("+\(TokenUsage.short(recent))/min").font(.system(size: 10, weight: .medium))
                    }
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
    private var members: [TerminalSession] { state.members(ofCluster: clusterId) }
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
                Text("· \(members.count) terminal\(members.count == 1 ? "" : "s")")
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

/// Every terminal card's frame — same-project cards double as "join this cluster" drop targets.
struct CardFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
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
