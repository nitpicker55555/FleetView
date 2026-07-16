import SwiftUI
import AppKit

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: state.sidebarWidth)
            SidebarDivider()
            VStack(spacing: 0) {
                TopBar()
                Divider().overlay(Theme.stroke)
                MainArea()
            }
        }
        .background(Theme.bg)
        .frame(minWidth: 960, minHeight: 580)
        .overlay { dragOverlay }
        .coordinateSpace(name: "fleet")
        .sheet(item: $state.nameSheet) { req in
            NameSheet(request: req).environmentObject(state)
        }
    }

    @ViewBuilder private var dragOverlay: some View {
        ZStack {
            if let dragId = state.draggingTerminalId {
                Color.black.opacity(0.16).ignoresSafeArea()
                VStack { Spacer(); ActionDock(terminalId: dragId).environmentObject(state) }
                if let t = state.terminals.first(where: { $0.id == dragId }) {
                    DragPreviewChip(name: t.name, status: t.status)
                        .position(x: state.dragLocation.x, y: state.dragLocation.y - 16)
                }
            }
        }
        .allowsHitTesting(false)   // purely visual; the drag is driven by the card gesture
        .animation(.easeOut(duration: 0.16), value: state.draggingTerminalId)
        .onPreferenceChange(ZoneFrameKey.self) { state.setZoneFrames($0) }
    }

    static func pickFolder(into state: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open Project"
        if panel.runModal() == .OK { for url in panel.urls { state.addProject(path: url.path) } }
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
            HStack(spacing: 0) {
                footerButton("Open Folder", "folder.badge.plus") { DashboardView.pickFolder(into: state) }
                Divider().frame(height: 20).overlay(Theme.stroke)
                footerButton("Clone", "arrow.down.circle") { showingClone = true }
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

    private func footerButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12)).foregroundColor(Theme.accent)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.panel.opacity(0.55))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
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

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.fill").font(.system(size: 12)).foregroundColor(Theme.accent.opacity(0.9))
            Text(project.name).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            Text("\(total)").font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Theme.card).foregroundColor(Theme.subtext).clipShape(Capsule())
            Text(project.path).font(.system(size: 11)).foregroundColor(Theme.subtext.opacity(0.6))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 10)
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
