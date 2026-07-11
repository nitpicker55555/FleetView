import AppKit
import SwiftUI

/// Single source of truth for the dashboard. Owns terminal window controllers (runtime,
/// not persisted) and the persisted projects/terminals/clusters.
@MainActor
final class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var terminals: [TerminalSession] = []
    @Published var clusters: [Cluster] = []
    @Published var selectedProjectId: UUID? = nil   // nil == All Projects
    @Published var sidebarWidth: Double = 236

    // Sidebar → dashboard focus: highlight (not raise) the matching card/cluster.
    @Published var highlightedTerminalId: UUID?
    @Published var highlightedClusterId: UUID?
    @Published var scrollToId: UUID?

    private var controllers: [UUID: TerminalWindowController] = [:]
    private var cascadePoint = NSPoint(x: 60, y: 60)
    var hookPort: Int? = nil

    // MARK: - Persistence

    private struct Persisted: Codable {
        var projects: [Project]
        var terminals: [TerminalSession]
        var clusters: [Cluster]
        var selectedProjectId: UUID?
        var sidebarWidth: Double?
    }

    func load() {
        FV.ensureSupportDir()
        guard let data = try? Data(contentsOf: FV.stateFile),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        projects = p.projects
        terminals = p.terminals.map { row in
            var t = row
            t.status = .closed        // live processes are gone after a relaunch
            t.sessionId = nil
            t.transcriptPath = nil
            return t
        }
        clusters = p.clusters
        selectedProjectId = p.selectedProjectId
        if let w = p.sidebarWidth { sidebarWidth = min(520, max(180, w)) }
    }

    func save() {
        FV.ensureSupportDir()
        let snapshot = terminals.map { t -> TerminalSession in
            var c = t
            if controllers[t.id] == nil { c.status = .closed }
            return c
        }
        let p = Persisted(projects: projects, terminals: snapshot,
                          clusters: clusters, selectedProjectId: selectedProjectId,
                          sidebarWidth: sidebarWidth)
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: FV.stateFile) }
    }

    // MARK: - Projects

    func addProject(path: String) {
        let url = URL(fileURLWithPath: path)
        if let existing = projects.first(where: { $0.path == path }) {
            selectedProjectId = existing.id
        } else {
            let isGit = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
            let proj = Project(name: url.lastPathComponent, path: path, isGit: isGit)
            projects.append(proj)
            selectedProjectId = proj.id
        }
        save()
    }

    func project(_ id: UUID?) -> Project? { projects.first { $0.id == id } }

    func removeProject(_ id: UUID) {
        for t in terminals.filter({ $0.projectId == id }) { removeTerminal(t.id) }
        projects.removeAll { $0.id == id }
        if selectedProjectId == id { selectedProjectId = nil }
        save()
    }

    // MARK: - Terminals

    @discardableResult
    func newTerminal(projectId: UUID, name: String? = nil, clusterId: UUID? = nil,
                     autoRunClaude: Bool = false) -> TerminalSession? {
        guard let proj = project(projectId) else { return nil }
        var t = TerminalSession(projectId: projectId,
                                name: name ?? defaultTerminalName(for: proj),
                                clusterId: clusterId, cwd: proj.path, autoRunClaude: autoRunClaude)
        t.status = .shell
        terminals.append(t)
        openWindow(for: t)
        save()
        return t
    }

    func reopenTerminal(_ id: UUID) {
        if controllers[id] != nil { raiseTerminal(id); return }
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[idx].status = .shell
        openWindow(for: terminals[idx])
        save()
    }

    func duplicateTerminal(_ id: UUID) {
        guard let src = terminals.first(where: { $0.id == id }) else { return }
        // Duplicate → both terminals belong to one cluster (they serve the same task).
        var clusterId = src.clusterId
        if clusterId == nil {
            let cluster = Cluster(name: src.name)
            clusters.append(cluster)
            clusterId = cluster.id
            if let i = terminals.firstIndex(where: { $0.id == src.id }) { terminals[i].clusterId = cluster.id }
        }
        _ = newTerminal(projectId: src.projectId, name: src.name,
                        clusterId: clusterId, autoRunClaude: src.autoRunClaude)
    }

    func raiseTerminal(_ id: UUID) {
        if let c = controllers[id] { c.raise() } else { reopenTerminal(id) }
    }

    func removeTerminal(_ id: UUID) {
        controllers[id]?.closeWindow()
        controllers[id] = nil
        terminals.removeAll { $0.id == id }
        pruneClusters()
        save()
    }

    func renameTerminal(_ id: UUID, to name: String) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[idx].name = name
        controllers[id]?.setTitle(name)
        save()
    }

    func toggleSubtaskDone(_ id: UUID) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[idx].subtaskDone.toggle()
        save()
    }

    // MARK: - Clusters (visual task grouping)

    func renameCluster(_ id: UUID, to name: String) {
        guard let i = clusters.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { clusters[i].name = n; save() }
    }

    /// Pop a terminal out of its cluster (becomes standalone again).
    func removeFromCluster(_ termId: UUID) {
        guard let i = terminals.firstIndex(where: { $0.id == termId }) else { return }
        terminals[i].clusterId = nil
        pruneClusters()
        save()
    }

    /// Add a fresh terminal to an existing cluster (another agent on the same task).
    func addToCluster(_ clusterId: UUID) {
        guard let anyMember = terminals.first(where: { $0.clusterId == clusterId }) else { return }
        _ = newTerminal(projectId: anyMember.projectId, name: cluster(clusterId)?.name, clusterId: clusterId)
    }

    func clustersInProject(_ projectId: UUID) -> [Cluster] {
        let ids = Set(terminals.filter { $0.projectId == projectId && $0.clusterId != nil }
                               .compactMap { $0.clusterId })
        return clusters.filter { ids.contains($0.id) }
    }

    func members(ofCluster clusterId: UUID) -> [TerminalSession] {
        terminals.filter { $0.clusterId == clusterId }
    }

    func standaloneTerminals(inProject projectId: UUID) -> [TerminalSession] {
        terminals.filter { $0.projectId == projectId && $0.clusterId == nil }
    }

    // MARK: - Tasks (sidebar) — standalone terminals + clusters

    var tasks: [TaskItem] {
        var result: [TaskItem] = []
        for p in projects {
            for c in clustersInProject(p.id) { result.append(.cluster(c.id)) }
            for t in standaloneTerminals(inProject: p.id) { result.append(.terminal(t.id)) }
        }
        return result
    }

    /// Worst-case status across a cluster's members (needs-you > running > returned > shell > gone).
    func clusterAggregateStatus(_ id: UUID) -> TermStatus {
        let m = members(ofCluster: id)
        if m.contains(where: { $0.status == .needsYou }) { return .needsYou }
        if m.contains(where: { $0.status == .working })  { return .working }
        if m.contains(where: { $0.status == .idle })     { return .idle }
        if m.contains(where: { $0.status == .shell })    { return .shell }
        if m.contains(where: { $0.status == .exited })   { return .exited }
        return .closed
    }

    func clusterDone(_ id: UUID) -> Bool {
        let m = members(ofCluster: id)
        return !m.isEmpty && m.allSatisfy { $0.subtaskDone }
    }

    /// Highlight and scroll to a task's card(s) in the dashboard — does NOT raise the window.
    func focusTask(_ task: TaskItem) {
        switch task {
        case .terminal(let id):
            highlightedTerminalId = id
            highlightedClusterId = nil
            scrollToId = id
        case .cluster(let id):
            highlightedClusterId = id
            highlightedTerminalId = nil
            scrollToId = id
        }
    }

    // MARK: - Finder

    func openInFinder(_ projectId: UUID) {
        guard let p = project(projectId) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p.path))
    }

    // MARK: - Name sheet (create / rename)

    enum NameSheetKind: Equatable { case newTerminal(UUID); case rename(UUID); case renameCluster(UUID) }
    struct NameSheetRequest: Identifiable {
        let id = UUID()
        let kind: NameSheetKind
        let initialName: String
        let title: String
        let confirmLabel: String
    }
    @Published var nameSheet: NameSheetRequest?

    func requestNewTerminal(projectId: UUID) {
        guard let proj = project(projectId) else { return }
        nameSheet = NameSheetRequest(kind: .newTerminal(projectId),
                                     initialName: defaultTerminalName(for: proj),
                                     title: "New Terminal", confirmLabel: "Open")
    }

    func requestRename(_ termId: UUID) {
        guard let t = terminals.first(where: { $0.id == termId }) else { return }
        nameSheet = NameSheetRequest(kind: .rename(termId), initialName: t.name,
                                     title: "Rename Terminal", confirmLabel: "Rename")
    }

    func requestRenameCluster(_ clusterId: UUID) {
        guard let c = cluster(clusterId) else { return }
        nameSheet = NameSheetRequest(kind: .renameCluster(clusterId), initialName: c.name,
                                     title: "Rename Cluster", confirmLabel: "Rename")
    }

    func confirmName(_ name: String) {
        guard let req = nameSheet else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty {
            switch req.kind {
            case .newTerminal(let pid):  _ = newTerminal(projectId: pid, name: n)
            case .rename(let id):        renameTerminal(id, to: n)
            case .renameCluster(let id): renameCluster(id, to: n)
            }
        }
        nameSheet = nil
    }

    // MARK: - Drag-to-act (self-managed gesture + manual hit-testing)

    enum DragZone: String, CaseIterable, Identifiable {
        case done, duplicate, rename, leaveCluster, remove
        var id: String { rawValue }
    }

    @Published var draggingTerminalId: UUID?
    @Published var dragLocation: CGPoint = .zero      // in the "fleet" coordinate space
    @Published var hoveredZone: DragZone?
    var zoneFrames: [DragZone: CGRect] = [:]          // reported by the dock, not published

    func availableZones(for id: UUID) -> [DragZone] {
        var zones: [DragZone] = [.done, .duplicate, .rename]
        if terminals.first(where: { $0.id == id })?.clusterId != nil { zones.append(.leaveCluster) }
        zones.append(.remove)
        return zones
    }

    func setZoneFrames(_ frames: [DragZone: CGRect]) { zoneFrames = frames }

    func dragChanged(_ id: UUID, to point: CGPoint) {
        if draggingTerminalId != id { draggingTerminalId = id }
        dragLocation = point
        hoveredZone = zoneAt(point)
    }

    func dragEnded(at point: CGPoint) {
        let zone = zoneAt(point)
        let id = draggingTerminalId
        draggingTerminalId = nil
        hoveredZone = nil
        if let id, let zone { perform(zone, on: id) }
    }

    func cancelDrag() { draggingTerminalId = nil; hoveredZone = nil }

    private func zoneAt(_ p: CGPoint) -> DragZone? {
        zoneFrames.first(where: { $0.value.contains(p) })?.key
    }

    private func perform(_ zone: DragZone, on id: UUID) {
        switch zone {
        case .done:         toggleSubtaskDone(id)
        case .duplicate:    duplicateTerminal(id)
        case .rename:       requestRename(id)
        case .leaveCluster: removeFromCluster(id)
        case .remove:       removeTerminal(id)
        }
    }

    func setStatus(_ id: UUID, _ s: TermStatus) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[idx].status = s
    }

    /// Apply a Claude Code hook event (delivered by EventWatcher) to the matching terminal.
    func handleHookEvent(_ ev: EventWatcher.Event) {
        guard let uid = UUID(uuidString: ev.term),
              let idx = terminals.firstIndex(where: { $0.id == uid }) else { return }
        if let sid = ev.sessionId { terminals[idx].sessionId = sid }
        if let tp = ev.transcriptPath { terminals[idx].transcriptPath = tp }

        switch ev.event {
        case "UserPromptSubmit":
            terminals[idx].status = .working
            if let p = ev.prompt {
                let oneLine = p.replacingOccurrences(of: "\n", with: " ")
                              .trimmingCharacters(in: .whitespacesAndNewlines)
                if !oneLine.isEmpty { terminals[idx].lastPrompt = oneLine }
            }
        case "Stop":
            terminals[idx].status = .idle
        case "Notification":
            terminals[idx].status = .needsYou
        case "SessionStart":
            // A Claude session is now active → leave "shell", show as an agent terminal.
            if terminals[idx].status != .working && terminals[idx].status != .needsYou {
                terminals[idx].status = .idle
            }
            if ev.source == "startup" {
                terminals[idx].lastPrompt = ""                    // brand-new session, no prompt yet
            } else if let tp = ev.transcriptPath {
                loadLatestPrompt(termId: uid, path: tp)           // resume/compact/clear → recover latest prompt
            }
        case "ShellCommand":
            // A plain (non-claude) command ran at the zsh prompt → back to "shell", show the command.
            terminals[idx].status = .shell
            if let c = ev.command, !c.isEmpty { terminals[idx].lastPrompt = c }
        default:
            break
        }
        save()
    }

    /// Read a resumed session's transcript off the main thread and show its latest user prompt.
    private func loadLatestPrompt(termId: UUID, path: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let prompt = Transcript.latestUserPrompt(path: path), !prompt.isEmpty else { return }
            Task { @MainActor in
                guard let self, let i = self.terminals.firstIndex(where: { $0.id == termId }) else { return }
                self.terminals[i].lastPrompt = prompt
                self.save()
            }
        }
    }

    // MARK: - Window plumbing

    private func openWindow(for t: TerminalSession) {
        let ctrl = TerminalWindowController(termId: t.id, title: t.name, cwd: t.cwd,
                                            autoRunClaude: t.autoRunClaude, port: hookPort)
        ctrl.onExit = { [weak self] id, _ in
            Task { @MainActor in self?.setStatus(id, .exited) }
        }
        ctrl.onClose = { [weak self] id in
            Task { @MainActor in self?.handleWindowClosed(id) }
        }
        controllers[t.id] = ctrl
        ctrl.show(cascadeFrom: &cascadePoint)
    }

    private func handleWindowClosed(_ id: UUID) {
        controllers[id] = nil
        if let idx = terminals.firstIndex(where: { $0.id == id }), terminals[idx].status != .exited {
            terminals[idx].status = .closed
        }
        save()
    }

    private func defaultTerminalName(for proj: Project) -> String {
        "\(proj.name)-\(terminals.filter { $0.projectId == proj.id }.count + 1)"
    }

    private func pruneClusters() {
        clusters.removeAll { cl in !terminals.contains { $0.clusterId == cl.id } }
    }

    // MARK: - Derived

    func terminals(inProject id: UUID?) -> [TerminalSession] {
        guard let id = id else { return terminals }
        return terminals.filter { $0.projectId == id }
    }

    func cluster(_ id: UUID?) -> Cluster? { clusters.first { $0.id == id } }
}
