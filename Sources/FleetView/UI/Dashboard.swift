import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: 236)
            Divider().overlay(Theme.stroke)
            VStack(spacing: 0) {
                TopBar()
                Divider().overlay(Theme.stroke)
                MainArea()
            }
        }
        .background(Theme.bg)
        .frame(minWidth: 960, minHeight: 580)
        .sheet(item: $state.nameSheet) { req in
            NameSheet(request: req).environmentObject(state)
        }
        .overlay {
            // Scoped to the overlay only, so drag state changes never animate the cards themselves.
            ZStack(alignment: .bottom) {
                if let dragId = state.draggingTerminalId {
                    Color.black.opacity(0.18).ignoresSafeArea()
                        .onDrop(of: [.text], isTargeted: nil) { _ in state.endDrag(); return true }  // drop elsewhere = cancel
                    ActionDock(terminalId: dragId).environmentObject(state)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: state.draggingTerminalId)
            .allowsHitTesting(state.draggingTerminalId != nil)
        }
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
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 16)

            HStack {
                Text("PROJECTS").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.subtext)
                Spacer()
                Text("\(state.projects.count)").font(.system(size: 11)).foregroundColor(Theme.subtext.opacity(0.7))
            }
            .padding(.horizontal, 16).padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ProjectRow(project: nil)   // "All Terminals" (scrolls to top)
                    ForEach(state.projects) { p in ProjectRow(project: p) }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
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

struct ProjectRow: View {
    @EnvironmentObject var state: AppState
    let project: Project?           // nil == "All Terminals"
    @State private var hover = false

    private var isAll: Bool { project == nil }
    private var terms: [TerminalSession] { isAll ? state.terminals : state.terminals(inProject: project!.id) }
    private var workingCount: Int { terms.filter { $0.status == .working }.count }
    private var selected: Bool { state.selectedProjectId == project?.id }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isAll ? "square.grid.2x2" : "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(selected ? Theme.accent : Theme.subtext)
                .frame(width: 15)
            Text(isAll ? "All Terminals" : project!.name)
                .font(.system(size: 13, weight: .medium)).foregroundColor(Theme.text).lineLimit(1)
            Spacer(minLength: 4)
            if hover && !isAll {
                Button { state.selectedProjectId = project!.id; state.requestNewTerminal(projectId: project!.id) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.subtext)
                }
                .buttonStyle(.plain).help("New terminal in this project")
            }
            if workingCount > 0 { Circle().fill(Theme.green).frame(width: 6, height: 6) }
            Text("\(terms.count)")
                .font(.system(size: 11)).foregroundColor(Theme.subtext.opacity(0.85))
                .frame(minWidth: 14, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Theme.accent.opacity(0.15) : (hover ? Theme.card : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { state.selectedProjectId = project?.id }
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
                .onChange(of: state.selectedProjectId) { _, id in
                    if let id { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) } }
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
                ForEach(clusters) { c in ClusterContainer(cluster: c) }
                if !standalone.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 14)],
                              alignment: .leading, spacing: 14) {
                        ForEach(standalone) { t in TerminalCardView(terminal: t) }
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
    let cluster: Cluster
    @State private var editingName = false

    private var members: [TerminalSession] { state.members(ofCluster: cluster.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 12)).foregroundColor(Theme.accent)
                Text("CLUSTER").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.accent.opacity(0.85))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.14)).clipShape(Capsule())
                EditableText(text: cluster.name,
                             font: .system(size: 14, weight: .semibold),
                             color: Theme.text,
                             onCommit: { state.renameCluster(cluster.id, to: $0) },
                             editing: $editingName)
                Button { editingName = true } label: {
                    Image(systemName: "pencil").font(.system(size: 10)).foregroundColor(Theme.subtext)
                }
                .buttonStyle(.plain).help("Rename task")
                Text("· \(members.count) terminal\(members.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundColor(Theme.subtext)
                Spacer()
                Button { state.addToCluster(cluster.id) } label: {
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
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accent.opacity(0.28), lineWidth: 1))
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
