import AppKit
import FleetViewAudit
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

    // Sidebar sections
    @Published var notes: [Note] = []
    @Published var tasksCollapsed: Bool = false
    @Published var notesCollapsed: Bool = false

    // Per-terminal cumulative new-token curve, rebuilt from transcripts (not persisted — recomputed).
    @Published var tokenSeries: [UUID: [TokenSample]] = [:]
    private var lastParsedTranscriptSize: [UUID: Int] = [:]
    private var lastTokenRefreshAt: [UUID: Date] = [:]

    // Sidebar → dashboard focus: highlight (not raise) the matching card/cluster.
    @Published var highlightedTerminalId: UUID?
    @Published var highlightedClusterId: UUID?
    @Published var scrollToId: UUID?

    private var controllers: [UUID: TerminalWindowController] = [:]
    private var cascadePoint = NSPoint(x: 60, y: 60)
    var hookPort: Int? = nil

    /// Serves terminals to other devices over the LAN (tmux + ttyd). Terminals run under tmux only
    /// when this is available; otherwise they fall back to a plain shell and remote access is off.
    let remote = RemoteServer()

    /// Serves the web dashboard (a mirror of this window, viewable + interactive from any device).
    let web = WebServer()

    // MARK: - Session tree (desktop panel)

    @Published var treePanelTerminalId: UUID?
    @Published var treePanelWidth: Double = 460
    let treeModel = SessionTreeModel()

    /// A node being dragged from the tree panel toward the board.
    struct TreeDrag {
        let nodeUuid: String
        let nativeSid: String?
        let prompt: String
        var location: CGPoint
    }
    @Published var treeDrag: TreeDrag?
    @Published var treeDropCardId: UUID?      // same-project card under the cursor → join its cluster
    @Published var treeBoardHot = false       // over the board → open standalone
    @Published var boardFrame: CGRect = .zero   // reported by MainArea; drives the inspector's placement
    var cardFrames: [UUID: CGRect] = [:]      // reported by each card

    /// Open the tree panel for a terminal's current session (project-dir scoped, treeflow-style).
    func openSessionTree(_ id: UUID) {
        treePanelTerminalId = id
        guard let path = transcriptPath(for: id) else {
            treeModel.showEmpty("此终端还没有 agent 会话\n发一条消息后再打开")
            return
        }
        if path.contains("/.codex/") {
            treeModel.showEmpty("Codex 会话树将在 v2 支持")
            return
        }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let sid = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        treeModel.open(projectDir: dir, boundSessionId: sid, sessions: treeSessionsInfo(projectDir: dir))
    }

    func closeSessionTree() {
        treePanelTerminalId = nil
        treeDrag = nil
        treeDropCardId = nil
        treeBoardHot = false
        treeModel.close()
    }

    /// sid → terminals currently on that session (name + status), for the panel's placement chips.
    private func treeSessionsInfo(projectDir: URL) -> [String: [(name: String, status: TermStatus)]] {
        var out: [String: [(String, TermStatus)]] = [:]
        for t in terminals {
            guard let p = hookSessionPath(for: t.id) ?? t.transcriptPath,
                  URL(fileURLWithPath: p).deletingLastPathComponent().path == projectDir.path
            else { continue }
            let sid = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
            out[sid, default: []].append((t.name, t.status))
        }
        return out
    }

    /// Keep the panel's terminal chips truthful as statuses/sessions move.
    func refreshTreeChips() {
        guard treePanelTerminalId != nil, let dir = treeModel.projectDir else { return }
        treeModel.updateSessions(treeSessionsInfo(projectDir: dir))
    }

    // MARK: Tree drag → drop targets

    func treeDragChanged(nodeUuid: String, nativeSid: String?, prompt: String, location: CGPoint) {
        if treeDrag == nil {
            treeDrag = TreeDrag(nodeUuid: nodeUuid, nativeSid: nativeSid, prompt: prompt, location: location)
        } else {
            treeDrag?.location = location
        }
        let srcProject = terminals.first { $0.id == treePanelTerminalId }?.projectId
        let card = cardFrames.first { entry in
            entry.value.contains(location)
                && terminals.first(where: { $0.id == entry.key })?.projectId == srcProject
                && entry.key != treePanelTerminalId   // dropping back onto the source card means "cluster with it" too — allow
        }?.key ?? cardFrames.first { entry in
            entry.value.contains(location)
                && terminals.first(where: { $0.id == entry.key })?.projectId == srcProject
        }?.key
        treeDropCardId = card
        treeBoardHot = card == nil && boardFrame.contains(location)
    }

    func treeDragEnded(at location: CGPoint) {
        let drag = treeDrag
        let card = treeDropCardId
        let boardHot = treeBoardHot
        treeDrag = nil
        treeDropCardId = nil
        treeBoardHot = false
        guard let d = drag else { return }
        if let card {
            forkOpenNode(nodeUuid: d.nodeUuid, nativeSid: d.nativeSid, prompt: d.prompt, joinClusterOf: card)
        } else if boardHot {
            forkOpenNode(nodeUuid: d.nodeUuid, nativeSid: d.nativeSid, prompt: d.prompt, joinClusterOf: nil)
        }
    }

    // MARK: Fork-open (tree node → new terminal)

    /// Open a new terminal resuming the given node: native sessions resume directly, everything else
    /// gets a synthesized fork file (treeflow's algorithm — the original session is never modified).
    func forkOpenNode(nodeUuid: String, nativeSid: String?, prompt: String, joinClusterOf targetCard: UUID?) {
        guard let srcId = treePanelTerminalId,
              let src = terminals.first(where: { $0.id == srcId }),
              let dir = treeModel.projectDir else { return }

        var clusterId: UUID?
        if let target = targetCard { clusterId = ensureCluster(for: target) }

        let shortPrompt = prompt.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = "⑂ " + String(shortPrompt.prefix(12))
        guard let newT = newTerminal(projectId: src.projectId, name: name,
                                     clusterId: clusterId, autoRunClaude: false) else { return }
        let createdAt = Date()

        let tmuxPath = remote.tmuxPath
        let srcSession = RemoteServer.sessionName(for: srcId)
        let srcTranscript = transcriptPath(for: srcId)
        let termCwd = src.cwd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let flags = tmuxPath.map {
                SessionForge.inheritedFlags(tmuxPath: $0, tmuxSocket: RemoteServer.socket,
                                            sessionName: srcSession)
            } ?? []
            do {
                let fork = try SessionForge.fork(projectDir: dir, targetUuid: nodeUuid,
                                                 nativeSessionId: nativeSid)
                let sessionCwd = SessionForge.sessionCwd(
                    transcriptPath: dir.appendingPathComponent("\(fork.sessionId).jsonl").path)
                    ?? SessionForge.sessionCwd(transcriptPath: srcTranscript ?? "")
                let cmd = SessionForge.resumeCommand(sessionId: fork.sessionId, inheritedFlags: flags,
                                                     cwd: sessionCwd == termCwd ? nil : sessionCwd)
                Task { @MainActor in
                    guard let self else { return }
                    FV.log("tree fork: node=\(nodeUuid.prefix(8)) sid=\(fork.sessionId.prefix(8)) " +
                           "native=\(fork.wroteFile == nil) chain=\(fork.chainLength)")
                    // Give the fresh tmux session a moment to reach a ready shell before typing.
                    let elapsed = Date().timeIntervalSince(createdAt)
                    self.typeIntoTerminal(newT.id, cmd, after: max(0.2, 1.4 - elapsed))
                }
            } catch {
                Task { @MainActor in
                    FV.log("tree fork FAILED: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Type a command into a terminal's shell after a delay (used by fork/duplicate flows).
    private func typeIntoTerminal(_ id: UUID, _ command: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.controllers[id]?.type(command + "\r")
        }
    }

    /// The terminal's cluster, creating one (named after it) when it has none — shared by
    /// duplicate and tree-drop-on-card.
    private func ensureCluster(for id: UUID) -> UUID? {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return nil }
        if let c = terminals[idx].clusterId { return c }
        let cluster = Cluster(name: terminals[idx].name)
        clusters.append(cluster)
        terminals[idx].clusterId = cluster.id
        return cluster.id
    }

    // MARK: - Dynamic panel (agent-authored UI pinned to the top)

    @Published var panelExists = false
    @Published var panelMtime: TimeInterval = 0
    /// UUIDv7 of the archived version currently on screen. Reloading on this rather than on mtime
    /// means `touch panel.html` no longer reflows the panel for nothing.
    @Published var panelVersion: String = ""
    private var panelTimer: Timer?

    /// Watch `~/.fleetview/ui/panel.html` so an agent can create / update / remove the panel *while*
    /// FleetView runs — it appears, reloads and disappears live, no relaunch. The polling lives here
    /// rather than in the view because a SwiftUI view that currently renders nothing (no panel yet)
    /// never receives timer events, which would make the panel appear only after a restart.
    func startPanelWatch() {
        try? FileManager.default.createDirectory(at: FV.uiDir, withIntermediateDirectories: true)
        refreshPanel()
        panelTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPanel() }
        }
        RunLoop.main.add(t, forMode: .common)   // keep ticking during menu tracking / scrolling
        panelTimer = t
    }

    private func refreshPanel() {
        // Archive the version before publishing the change, so `panelVersion` never names a uuid
        // that has not been written yet.
        PanelVersions.shared.check(auditor: audit) { [weak self] in
            guard let self else { return .unknown }
            return AppAudit.shared.panelAttribution(active: self.panelWriteCandidates(), at: Date())
        }
        if panelVersion != (PanelVersions.shared.currentUUID ?? "") {
            panelVersion = PanelVersions.shared.currentUUID ?? ""
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: FV.panelHTML.path)
        let exists = attrs != nil
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if exists != panelExists {
            panelExists = exists
            FV.log("panel \(exists ? "appeared" : "removed")")
        }
        if mtime != panelMtime { panelMtime = mtime }
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var projects: [Project]
        var terminals: [TerminalSession]
        var clusters: [Cluster]
        var selectedProjectId: UUID?
        var sidebarWidth: Double?
        var notes: [Note]?
        var tasksCollapsed: Bool?
        var notesCollapsed: Bool?
        var treePanelWidth: Double?
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
            return t                   // keep transcriptPath so we can rebuild the token curve
        }
        clusters = p.clusters
        selectedProjectId = p.selectedProjectId
        if let w = p.sidebarWidth { sidebarWidth = min(520, max(180, w)) }
        notes = p.notes ?? []
        tasksCollapsed = p.tasksCollapsed ?? false
        notesCollapsed = p.notesCollapsed ?? false
        if let w = p.treePanelWidth { treePanelWidth = min(720, max(380, w)) }
        // Rebuild each terminal's token curve from its transcript (background; badge shows meanwhile).
        for t in terminals { if let tp = t.transcriptPath { refreshTokens(t.id, path: tp) } }
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
                          sidebarWidth: sidebarWidth, notes: notes,
                          tasksCollapsed: tasksCollapsed, notesCollapsed: notesCollapsed,
                          treePanelWidth: treePanelWidth)
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
        guard let proj = project(projectId) else {
            audit.failure("fleetview.terminal.create_failed", reason: "unknown project",
                          categories: ["process"],
                          data: ["project.id": .string(projectId.uuidString)])
            return nil
        }
        return audited(AuditIntent("terminal.create",
                                   data: ["name_source": .string(name == nil ? "auto" : "user")])) {
            var t = TerminalSession(projectId: projectId,
                                    name: name ?? defaultTerminalName(for: proj),
                                    clusterId: clusterId, cwd: proj.path, autoRunClaude: autoRunClaude)
            t.status = .shell
            terminals.append(t)
            openWindow(for: t)
            save()
            return t
        }
    }

    func reopenTerminal(_ id: UUID) {
        if controllers[id] != nil { raiseTerminal(id); return }
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[idx].status = .shell
        openWindow(for: terminals[idx])
        save()
    }

    /// On launch, silently reattach every terminal whose tmux session is still alive (FleetView was
    /// closed/updated but the shells + agents kept running under tmux). Each gets its window back,
    /// attached to the exact same session — no `claude` is re-typed (the session already exists).
    /// Terminals whose shell had exited leave no session and are simply left `closed`.
    func reconnectLiveTerminals() {
        guard remote.available else { return }
        let live = remote.liveSessions()
        guard !live.isEmpty else { return }
        var reattached = 0
        for t in terminals where controllers[t.id] == nil
              && live.contains(RemoteServer.sessionName(for: t.id)) {
            openWindow(for: t)
            if let i = terminals.firstIndex(where: { $0.id == t.id }) {
                // A reconnected agent is most likely idle (waiting); a plain shell shows as shell.
                // Live hook events refine this within a turn.
                terminals[i].status = t.agentKind != .unknown ? .idle : .shell
            }
            reattached += 1
        }
        if reattached > 0 { FV.log("reconnected \(reattached) live terminal(s) on launch"); save() }
    }

    /// Duplicate → both terminals belong to one cluster (they serve the same task).
    /// When the source has a live Claude session, the duplicate FORKS it — same conversation
    /// context in a brand-new session (`--resume <sid> --fork-session`), original untouched.
    /// `blank: true` keeps the old behaviour (fresh empty terminal).
    func duplicateTerminal(_ id: UUID, blank: Bool = false) {
        guard let src = terminals.first(where: { $0.id == id }) else { return }
        let clusterId = ensureCluster(for: id)

        var forkSid: String?
        if !blank, let path = hookSessionPath(for: id) ?? src.transcriptPath,
           !path.contains("/.codex/"), FileManager.default.fileExists(atPath: path) {
            forkSid = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        guard let sid = forkSid else {
            _ = newTerminal(projectId: src.projectId, name: src.name,
                            clusterId: clusterId, autoRunClaude: src.autoRunClaude)
            return
        }

        guard let newT = newTerminal(projectId: src.projectId, name: src.name + " ⑂",
                                     clusterId: clusterId, autoRunClaude: false) else { return }
        let createdAt = Date()
        let tmuxPath = remote.tmuxPath
        let srcSession = RemoteServer.sessionName(for: id)
        let srcTranscript = hookSessionPath(for: id) ?? src.transcriptPath
        let termCwd = src.cwd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let flags = tmuxPath.map {
                SessionForge.inheritedFlags(tmuxPath: $0, tmuxSocket: RemoteServer.socket,
                                            sessionName: srcSession)
            } ?? []
            let sessionCwd = srcTranscript.flatMap { SessionForge.sessionCwd(transcriptPath: $0) }
            let cmd = SessionForge.resumeCommand(sessionId: sid, inheritedFlags: flags, forkSession: true,
                                                 cwd: sessionCwd == termCwd ? nil : sessionCwd)
            Task { @MainActor in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(createdAt)
                self.typeIntoTerminal(newT.id, cmd, after: max(0.2, 1.4 - elapsed))
            }
        }
    }

    func raiseTerminal(_ id: UUID) {
        // Raising changes no model state, so the audit diff cannot see it — clicking a card would
        // vanish from the log without this declared intent.
        let wasOpen = controllers[id] != nil
        audited(AuditIntent("terminal.raise",
                            event: "fleetview.terminal.raised",
                            categories: ["process"],
                            target: auditTarget(terminal: id),
                            data: ["was_open": .bool(wasOpen)],
                            message: "raised \(terminals.first { $0.id == id }?.name ?? "terminal")")) {
            if let c = controllers[id] { c.raise() } else { reopenTerminal(id) }
        }
    }

    func removeTerminal(_ id: UUID) {
        audited(AuditIntent("terminal.remove")) { removeTerminalUnaudited(id) }
    }

    private func removeTerminalUnaudited(_ id: UUID) {
        if treePanelTerminalId == id { closeSessionTree() }
        controllers[id]?.closeWindow()
        controllers[id] = nil
        remote.stop(id)                 // kill this terminal's web server + tmux session
        terminals.removeAll { $0.id == id }
        tokenSeries[id] = nil
        lastParsedTranscriptSize[id] = nil
        lastTokenRefreshAt[id] = nil
        pruneClusters()
        save()
    }

    func renameTerminal(_ id: UUID, to name: String) {
        audited(AuditIntent("terminal.rename")) {
            guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
            terminals[idx].name = name
            controllers[id]?.setTitle(name)
            save()
        }
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

    /// Tasks grouped by project (only projects that have at least one task).
    var taskGroups: [TaskGroup] {
        projects.compactMap { p in
            var items: [TaskItem] = []
            for c in clustersInProject(p.id) { items.append(.cluster(c.id)) }
            for t in standaloneTerminals(inProject: p.id) { items.append(.terminal(t.id)) }
            return items.isEmpty ? nil : TaskGroup(project: p, tasks: items)
        }
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

    // MARK: - Notes

    func addNote(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        notes.append(Note(text: t))
        save()
    }

    /// Commit an edit. Committing empty text deletes the note (a simple, discoverable delete path).
    func updateNote(_ id: UUID, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { notes.remove(at: i) } else { notes[i].text = t }
        save()
    }

    func removeNote(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    // MARK: - Finder

    func openInFinder(_ projectId: UUID) {
        guard let p = project(projectId) else { return }
        audited(AuditIntent("project.reveal",
                            event: "fleetview.project.revealed",
                            categories: ["configuration"],
                            target: AuditTarget(kind: "project", id: p.id.uuidString, name: p.name,
                                                fields: ["project.path": .string(p.path)]),
                            message: "revealed \(p.name) in Finder")) {
            NSWorkspace.shared.open(URL(fileURLWithPath: p.path))
        }
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

    /// While a card is being dragged, the right edge becomes a drop target that opens that
    /// terminal's session tree — the same edge the panel itself slides out from.
    @Published var hoveredTreeZone = false
    var sessionTreeZoneFrame: CGRect {
        guard boardFrame != .zero else { return .zero }
        let w: CGFloat = 96
        return CGRect(x: boardFrame.maxX - w, y: boardFrame.minY, width: w, height: boardFrame.height)
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
        // The dock's explicit zones win; the edge only claims what they don't.
        hoveredTreeZone = hoveredZone == nil && sessionTreeZoneFrame.contains(point)
    }

    func dragEnded(at point: CGPoint) {
        let zone = zoneAt(point)
        let onTreeZone = hoveredTreeZone
        let id = draggingTerminalId
        draggingTerminalId = nil
        hoveredZone = nil
        hoveredTreeZone = false
        guard let id else { return }
        if let zone { perform(zone, on: id) }
        else if onTreeZone { openSessionTree(id) }
    }

    func cancelDrag() { draggingTerminalId = nil; hoveredZone = nil; hoveredTreeZone = false }

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

    /// The user pressed Escape (Claude's interrupt) — if the agent was working, the turn just ended,
    /// so clear the stuck "working" immediately (no Stop hook fires on an interrupt).
    func handleInterrupt(_ id: UUID) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[idx].lastActivity = Date()   // pressing Esc is a real interaction
        guard terminals[idx].status == .working else { return }
        terminals[idx].status = .idle
        save()
    }

    /// Apply a Claude Code hook event (delivered by EventWatcher) to the matching terminal.
    func handleHookEvent(_ ev: EventWatcher.Event) {
        guard let uid = UUID(uuidString: ev.term),
              let idx = terminals.firstIndex(where: { $0.id == uid }) else { return }
        // Everything this hook provokes is the agent's (or the shell's) doing, not the user's at the
        // keyboard — declaring it once here attributes the whole cascade correctly.
        AuditContext.with(hookActor(ev, terminal: terminals[idx])) {
            auditHookEvent(ev, terminal: uid)
            applyHookEvent(ev, uid: uid, idx: idx)
        }
    }

    private func applyHookEvent(_ ev: EventWatcher.Event, uid: UUID, idx: Int) {
        FV.log("evt=\(ev.event) term=\(terminals[idx].name) src=\(ev.source ?? "-") msg=\(ev.message ?? "-")")
        terminals[idx].lastActivity = Date()   // a hook fired → real agent/shell activity in this terminal
        if let sid = ev.sessionId { terminals[idx].sessionId = sid }
        if let tp = ev.transcriptPath {
            terminals[idx].transcriptPath = tp
            // Tell Claude vs Codex apart by where the transcript lives (drives the card's colour cue).
            if tp.contains("/.codex/") { terminals[idx].agentKind = .codex }
            else if tp.contains("/.claude/") { terminals[idx].agentKind = .claude }
        }

        switch ev.event {
        case "UserPromptSubmit":
            terminals[idx].status = .working
            if let p = ev.prompt {
                let oneLine = p.replacingOccurrences(of: "\n", with: " ")
                              .trimmingCharacters(in: .whitespacesAndNewlines)
                if !oneLine.isEmpty { terminals[idx].lastPrompt = oneLine }
            }
        case "PreToolUse", "PostToolUse":
            // A tool is starting/finishing → the agent is actively working. Crucially this clears a
            // prior "needs you" the moment the user approves a permission prompt (Claude & Codex).
            if terminals[idx].status != .working { terminals[idx].status = .working }
        case "PermissionRequest":
            // Codex fires this before an approval prompt (Claude uses "Notification", handled below).
            terminals[idx].status = .needsYou
        case "Stop":
            terminals[idx].status = .idle
        case "Notification":
            // The Notification hook fires for BOTH permission requests and idle "waiting for input".
            // Only a permission/approval request is a genuine "needs you"; idle just means returned.
            let msg = (ev.message ?? "").lowercased()
            if msg.contains("permission") || msg.contains("approve") || msg.contains("approval") || msg.contains("confirm") {
                terminals[idx].status = .needsYou
            } else if msg.contains("waiting") || msg.contains("finished") || msg.contains("idle") {
                terminals[idx].status = .idle   // explicit idle signal clears a stuck "working" (e.g. after an interrupt)
            } else if terminals[idx].status != .working {
                terminals[idx].status = .idle
            }
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
            // `claude` still reports itself so the *act of starting an agent* is audited, but it must
            // not drag the card back to "shell" — its own hooks own the status from here.
            guard !ev.quiet else { break }
            terminals[idx].status = .shell
            if let c = ev.command, !c.isEmpty {
                terminals[idx].lastPrompt = c
                if c.hasPrefix("codex") { terminals[idx].agentKind = .codex }
            }
        default:
            break
        }
        // Refresh the token curve from the transcript as the turn progresses (skipped if unchanged).
        if let tp = terminals[idx].transcriptPath,
           ["Stop", "PostToolUse", "PreToolUse", "SessionStart"].contains(ev.event) {
            refreshTokens(uid, path: tp, force: ev.event == "Stop")
        }
        refreshTreeChips()
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

    // MARK: - Token usage

    /// Re-read a terminal's transcript off the main thread and update its new-token curve + total.
    /// Cheap: debounced to ~1s (force-through on turn end), and skips the parse when the file is unchanged.
    func refreshTokens(_ termId: UUID, path: String, force: Bool = false) {
        let now = Date()
        if !force, let last = lastTokenRefreshAt[termId], now.timeIntervalSince(last) < 1.0 { return }
        lastTokenRefreshAt[termId] = now
        let prev = lastParsedTranscriptSize[termId]
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
            if let size, let prev, size == prev { return }
            let series = TokenUsage.series(path: path).map { TokenSample(t: $0.t, newTokens: $0.cumulativeNew) }
            let total = series.last?.newTokens ?? 0
            Task { @MainActor in
                guard let self else { return }
                if let size { self.lastParsedTranscriptSize[termId] = size }
                self.tokenSeries[termId] = series
                if let i = self.terminals.firstIndex(where: { $0.id == termId }), self.terminals[i].newTokens != total {
                    self.terminals[i].newTokens = total   // persisted on the next save()
                }
            }
        }
    }

    /// Total new tokens used across a project's terminals.
    func projectNewTokens(_ projectId: UUID) -> Int {
        terminals.filter { $0.projectId == projectId }.reduce(0) { $0 + $1.newTokens }
    }

    /// Merge every member terminal's cumulative curve into one project curve over time (sum of
    /// sessions): diff each session to per-interval deltas, merge by time, re-accumulate.
    func projectTokenCurve(_ projectId: UUID) -> [TokenSample] {
        let ids = terminals.filter { $0.projectId == projectId }.map { $0.id }
        var deltas: [(Date, Int)] = []
        for id in ids {
            guard let s = tokenSeries[id], !s.isEmpty else { continue }
            var prev = 0
            for pt in s { deltas.append((pt.t, pt.newTokens - prev)); prev = pt.newTokens }
        }
        guard !deltas.isEmpty else { return [] }
        deltas.sort { $0.0 < $1.0 }
        var cum = 0
        return deltas.map { entry in cum += entry.1; return TokenSample(t: entry.0, newTokens: cum) }
    }

    /// New tokens a project accrued in the last `seconds` (default 60) — a live "tokens/min" rate.
    func projectTokensRecent(_ projectId: UUID, now: Date, seconds: TimeInterval = 60) -> Int {
        let cutoff = now.addingTimeInterval(-seconds)
        var sum = 0
        for t in terminals where t.projectId == projectId {
            guard let s = tokenSeries[t.id], let last = s.last else { continue }
            let base = s.last(where: { $0.t <= cutoff })?.newTokens ?? 0
            sum += max(0, last.newTokens - base)
        }
        return sum
    }

    /// Per-turn token *increments* aggregated into FIXED absolute-time buckets over the last `window`
    /// (default 1h). Fixed buckets (not data-relative) keep every bar in a stable x position — new data
    /// only grows the rightmost bar instead of reshuffling the whole chart. Each sample's `newTokens`
    /// is the increment, not a running total.
    func projectTokenDeltas(_ projectId: UUID, window: TimeInterval = 3600, bars: Int = 40) -> [TokenSample] {
        let cutoff = Date().addingTimeInterval(-window)
        let width = max(1, window / Double(bars))
        var sums: [Double: Int] = [:]   // bucket-start (ref-date seconds) → tokens
        for t in terminals where t.projectId == projectId {
            guard let s = tokenSeries[t.id], !s.isEmpty else { continue }
            var prev = 0
            for pt in s {
                let d = pt.newTokens - prev; prev = pt.newTokens
                guard d > 0, pt.t >= cutoff else { continue }
                let slot = (pt.t.timeIntervalSinceReferenceDate / width).rounded(.down) * width
                sums[slot, default: 0] += d
            }
        }
        return sums.keys.sorted().map {
            TokenSample(t: Date(timeIntervalSinceReferenceDate: $0 + width / 2), newTokens: sums[$0]!)
        }
    }

    /// Most recent token-event time across a project (for the chart's "updated" caption).
    func projectLastTokenTime(_ projectId: UUID) -> Date? {
        terminals.filter { $0.projectId == projectId }.compactMap { tokenSeries[$0.id]?.last?.t }.max()
    }

    // MARK: - Remote (web) access

    /// Start (or reuse) the web server for a terminal and return its LAN URL for the card's popover.
    func remoteEndpoint(for id: UUID) -> RemoteServer.Endpoint? {
        guard let t = terminals.first(where: { $0.id == id }) else { return nil }
        return remote.endpoint(for: id, name: t.name)
    }

    /// The web dashboard's LAN URL (for the top-bar popover / QR). nil until the server is up.
    var webDashboardURL: String? {
        guard web.port > 0, let ip = Tooling.preferredIP() else { return nil }
        return "http://\(ip):\(web.port)/"
    }

    /// Route a web request to (httpStatus, contentType, body). Called on the main actor by WebServer.
    func webResponse(path: String, query: [String: String]) -> (String, String, Data) {
        switch path {
        case "/", "/index.html":
            return ("200 OK", "text/html; charset=utf-8", Data(WebDashboardPage.html.utf8))
        case "/state":
            let data = (try? JSONEncoder().encode(webSnapshot())) ?? Data("{}".utf8)
            return ("200 OK", "application/json", data)
        case "/open":
            guard let s = query["id"], let id = UUID(uuidString: s) else {
                return ("400 Bad Request", "application/json", Data(#"{"error":"bad id"}"#.utf8))
            }
            if let ep = webOpenTerminal(id),
               let body = try? JSONEncoder().encode(["url": ep.url, "port": String(ep.port)]) {
                return ("200 OK", "application/json", body)   // client rebuilds URL from its own host (LAN / Tailscale)
            }
            return ("409 Conflict", "application/json", Data(#"{"error":"not open"}"#.utf8))
        case "/new":
            guard let s = query["projectId"], let pid = UUID(uuidString: s) else {
                return ("400 Bad Request", "application/json", Data(#"{"error":"bad id"}"#.utf8))
            }
            let t = newTerminal(projectId: pid)
            let body = try? JSONEncoder().encode(["id": t?.id.uuidString ?? ""])
            return ("200 OK", "application/json", body ?? Data("{}".utf8))
        case "/action":
            guard let s = query["id"], let id = UUID(uuidString: s), let act = query["do"] else {
                return ("400 Bad Request", "application/json", Data(#"{"error":"bad id"}"#.utf8))
            }
            webAction(id, act, name: query["name"])
            return ("200 OK", "application/json", Data(#"{"ok":true}"#.utf8))
        case "/type":
            guard let s = query["id"], let id = UUID(uuidString: s) else {
                return ("400 Bad Request", "application/json", Data(#"{"error":"bad id"}"#.utf8))
            }
            remote.sendText(id, text: query["text"] ?? "", enter: query["enter"] == "1")
            markActivity(id)
            return ("200 OK", "application/json", Data(#"{"ok":true}"#.utf8))
        case "/key":
            guard let s = query["id"], let id = UUID(uuidString: s), let k = query["k"] else {
                return ("400 Bad Request", "application/json", Data(#"{"error":"bad id"}"#.utf8))
            }
            remote.sendKey(id, k)
            markActivity(id)
            // Interrupting ends the turn without any hook firing (there's no Stop event for a
            // cancelled turn), so the card and the chat would sit on "running" forever. The desktop
            // Esc monitor already corrects this locally; do the same for a remote interrupt.
            if k == "Escape" || k == "C-c" { handleInterrupt(id) }
            return ("200 OK", "application/json", Data(#"{"ok":true}"#.utf8))
        case "/scroll":
            guard let s = query["id"], let id = UUID(uuidString: s) else {
                return ("400 Bad Request", "application/json", Data(#"{"error":"bad id"}"#.utf8))
            }
            remote.scroll(id, up: query["dir"] != "down")
            return ("200 OK", "application/json", Data(#"{"ok":true}"#.utf8))
        case "/note":
            // Manage the shared Notes list from the web (it drives the quick-command chips).
            if let add = query["add"] { addNote(add) }
            else if let d = query["del"], let nid = UUID(uuidString: d) { removeNote(nid) }
            return ("200 OK", "application/json", Data(#"{"ok":true}"#.utf8))
        case "/favicon.ico":
            // Answer once instead of 404-ing forever: browsers ask unprompted and keep retrying.
            return ("204 No Content", "image/x-icon", Data())
        case "/select":
            // A beacon: the web page tells the server which terminal the user opened. Without it,
            // "what were they looking at" would have to be guessed from a polling endpoint, whose
            // meaning would drift the moment the poll interval changed.
            return ("200 OK", "application/json", Data(#"{"ok":true}"#.utf8))
        case "/panel":
            // The agent-authored dynamic panel (self-contained HTML). Empty page if none written yet.
            // `?v=<uuid>` replays an archived version instead of the current one.
            if let uuid = query["v"], !uuid.isEmpty {
                guard let html = PanelVersions.shared.html(uuid: uuid) else {
                    return ("404 Not Found", "text/plain", Data("no such panel version".utf8))
                }
                return ("200 OK", "text/html; charset=utf-8", Data(html.utf8))
            }
            let html = (try? String(contentsOf: FV.panelHTML, encoding: .utf8)) ?? "<!doctype html><body></body>"
            return ("200 OK", "text/html; charset=utf-8", Data(html.utf8))
        case "/panel-versions":
            // Newest first; each line is one archived version with its provenance.
            let lines = PanelVersions.shared.recentVersions(limit: min(200, Int(query["limit"] ?? "") ?? 50))
            return ("200 OK", "application/json", Data("[\(lines.joined(separator: ","))]".utf8))
        case "/panel-data":
            // Fast-changing data the panel's own JS polls via fetch('/panel-data').
            let data = (try? Data(contentsOf: FV.panelJSON)) ?? Data("{}".utf8)
            return ("200 OK", "application/json", data)
        case "/panel-meta":
            // Container polls this to know whether a panel exists and when to reload (html changed).
            let attrs = try? FileManager.default.attributesOfItem(atPath: FV.panelHTML.path)
            let exists = attrs != nil
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            // `uuid` is the reliable reload signal: mtime moves when the file is merely touched.
            let body = try? JSONSerialization.data(withJSONObject: [
                "exists": exists ? 1 : 0,
                "mtime": Int(mtime),
                "uuid": PanelVersions.shared.currentUUID ?? "",
            ])
            return ("200 OK", "application/json", body ?? Data(#"{"exists":0,"mtime":0}"#.utf8))
        case "/conversation":
            // Structured conversation for the web view — renders as chat with native scrolling,
            // which is how you read history on a phone (the terminal mirror can't scroll a TUI).
            guard let s = query["id"], let id = UUID(uuidString: s) else {
                return ("400 Bad Request", "application/json", Data(#"{"error":"bad id"}"#.utf8))
            }
            guard let path = transcriptPath(for: id) else {
                // No agent conversation (a plain shell, or one that hasn't started yet): the pane's
                // own scrollback is the readable content, and it scrolls natively on a phone.
                var info = ConvInfo()
                info.status = terminals.first(where: { $0.id == id })?.status.rawValue
                info.shell = true
                let body = (try? JSONEncoder().encode(ConvResult(messages: [], info: info)))
                    ?? Data(#"{"messages":[],"info":{"shell":true}}"#.utf8)
                return ("200 OK", "application/json", body)
            }
            let limit = min(400, Int(query["limit"] ?? "") ?? 120)
            let t = terminals.first(where: { $0.id == id })
            var result = Conversation.parse(path: path, cwd: t?.cwd ?? "", limit: limit,
                                            ownPrompt: t?.lastPrompt ?? "")
            result.info.contextWindow = Conversation.contextWindow(model: result.info.model,
                                                                  used: result.info.contextTokens)
            result.info.status = t?.status.rawValue
            result.info.session = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            result.info.shared = terminalsSharing(path)
            // Read the choices off the live screen so a prompt can be answered with real buttons.
            // Gated on the picker's cursor rather than on status, because trust/menu prompts don't
            // always raise "needs you" — the cursor is what actually means "waiting on you".
            if let screen = remote.capture(id, lines: 40) {
                let parsed = Conversation.options(fromScreen: screen)
                result.info.options = parsed.options
                result.info.question = parsed.question
            }
            let body = (try? JSONEncoder().encode(result)) ?? Data(#"{"messages":[]}"#.utf8)
            return ("200 OK", "application/json", body)
        case "/capture":
            // Recent screen + scrollback of a terminal (for `fleetctl` conversation view / error scan).
            guard let s = query["id"], let id = UUID(uuidString: s) else {
                return ("400 Bad Request", "text/plain", Data("bad id".utf8))
            }
            let n = Int(query["lines"] ?? "") ?? 200
            return ("200 OK", "text/plain; charset=utf-8", Data((remote.capture(id, lines: n) ?? "").utf8))
        default:
            return ("404 Not Found", "text/plain", Data("not found".utf8))
        }
    }

    /// Resolve what `/ask` needs for a terminal: the agent session id (from its transcript), cwd, and
    /// agent kind. nil if no agent session has been captured yet (nothing to fork a query from).
    func askSpec(_ id: UUID) -> AskSpec? {
        guard let t = terminals.first(where: { $0.id == id }), let path = transcriptPath(for: id) else { return nil }
        let sid = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !sid.isEmpty else { return nil }
        return AskSpec(sessionId: sid, cwd: t.cwd, agent: t.agentKind.rawValue)
    }

    /// The agent transcript file for a terminal: the path its own hooks reported, else — only when
    /// nothing else has claimed it — the newest unclaimed session for that cwd (covers a session
    /// started before hooks caught up).
    ///
    /// The fallback must never hand back another terminal's transcript: several terminals usually
    /// share a project directory, so "newest file in this cwd" would show a brand-new terminal the
    /// conversation belonging to a completely different one.
    func transcriptPath(for id: UUID) -> String? {
        guard let t = terminals.first(where: { $0.id == id }) else { return nil }
        // The pointer hook.sh writes for this terminal wins: it is rewritten on every hook event, so
        // it survives a missed event or a `claude --resume` that switched sessions, both of which
        // leave the value we cached from the event stream pointing at the wrong conversation.
        if let live = hookSessionPath(for: id) { return live }
        if let tp = t.transcriptPath, FileManager.default.fileExists(atPath: tp) { return tp }
        // A plain shell has no conversation at all — never guess one for it, or it would inherit
        // some unrelated session from the same project.
        guard t.agentKind != .unknown || t.status.isAgent else { return nil }
        let claimed = Set(terminals.filter { $0.id != id }.compactMap { $0.transcriptPath })
        let dir = FV.transcriptDir(forCwd: t.cwd)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.pathExtension == "jsonl" && !claimed.contains($0.path) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
        return newest?.path
    }

    /// The transcript this terminal's agent is writing *right now*, per the pointer its own hook
    /// maintains at ~/.fleetview/sessions/<termId>.json. nil when the terminal has never run an
    /// agent, or the file it names has since been removed.
    func hookSessionPath(for id: UUID) -> String? {
        guard let data = try? Data(contentsOf: FV.sessionPointer(for: id)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["transcript_path"] as? String,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// How many terminals point at the same transcript. >1 means the conversation genuinely belongs
    /// to a session several terminals share, so identical chat content is expected, not a bug.
    func terminalsSharing(_ path: String) -> Int {
        terminals.filter { (hookSessionPath(for: $0.id) ?? $0.transcriptPath) == path }.count
    }

    /// Typing/keys from the web are real interaction — record it (drives "3m ago").
    private func markActivity(_ id: UUID) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[idx].lastActivity = Date()
    }

    /// Perform a card action requested from the web (mirrors the desktop drag-to-act zones).
    private func webAction(_ id: UUID, _ act: String, name: String?) {
        // Wrapped so that an action naming a terminal that no longer exists still leaves a trace:
        // it changes nothing, so the state diff alone would show a silent no-op.
        audited(AuditIntent("web.action",
                            categories: ["web"],
                            target: auditTarget(terminal: id),
                            data: AuditValue.compact(["do": .string(act), "name": name.map { .string($0) }]),
                            message: "web action \(act)")) {
            performWebAction(id, act, name: name)
        }
    }

    private func performWebAction(_ id: UUID, _ act: String, name: String?) {
        switch act {
        case "done":         toggleSubtaskDone(id)
        case "duplicate":    duplicateTerminal(id)
        case "remove":       removeTerminal(id)
        case "leaveCluster": removeFromCluster(id)
        case "rename":       if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { renameTerminal(id, to: n) }
        default:             break
        }
    }

    /// Build the live snapshot the web page renders.
    private func webSnapshot() -> WebSnapshot {
        // One cached list-sessions so a "closed" terminal whose tmux session is still alive stays
        // openable (reattach from the web) — not one has-session call per terminal.
        let live = remote.available ? remote.liveSessions() : []
        let terms = terminals.map { t in
            WebSnapshot.Term(id: t.id.uuidString, name: t.name, projectId: t.projectId.uuidString,
                             clusterId: t.clusterId?.uuidString, status: t.status.rawValue,
                             statusLabel: t.status.label, agent: t.agentKind.label,
                             prompt: t.lastPrompt, tokens: t.newTokens,
                             canOpen: live.contains(RemoteServer.sessionName(for: t.id)),  // authoritative: only if THIS instance has the session
                             done: t.subtaskDone,
                             idle: t.lastActivity.map { max(0, Int(Date().timeIntervalSince($0))) } ?? -1,
                             cwd: t.cwd,
                             transcript: t.transcriptPath)
        }
        return WebSnapshot(
            projects: projects.map { .init(id: $0.id.uuidString, name: $0.name, path: $0.path) },
            terminals: terms,
            clusters: clusters.map { .init(id: $0.id.uuidString, name: $0.name) },
            notes: notes.map { .init(id: $0.id.uuidString, text: $0.text) },
            working: terminals.filter { $0.status == .working }.count,
            needs: terminals.filter { $0.status == .needsYou }.count,
            remoteOK: remote.available,
            remoteHint: remote.unavailableReason)
    }

    /// Start (or reuse) a web terminal for an open session and return its URL (nil if not attachable).
    private func webOpenTerminal(_ id: UUID) -> RemoteServer.Endpoint? {
        guard remote.available, let t = terminals.first(where: { $0.id == id }) else { return nil }
        guard remote.sessionExists(id) else { return nil }
        return remote.endpoint(for: id, name: t.name)
    }

    // MARK: - Window plumbing

    private func openWindow(for t: TerminalSession) {
        // Run under tmux when remote access is available (so the web view can attach to the same
        // session). Only auto-type `claude` when we're *creating* the session — re-attaching to a
        // persisted one (reopen after the window was closed) would spawn a second claude.
        let spec = remote.tmuxSpec(for: t.id)
        let autoRun = t.autoRunClaude && !(spec != nil && remote.sessionExists(t.id))
        let ctrl = TerminalWindowController(termId: t.id, title: t.name, cwd: t.cwd,
                                            autoRunClaude: autoRun, port: hookPort, tmux: spec)
        ctrl.onExit = { [weak self] id, _ in
            Task { @MainActor in self?.setStatus(id, .exited) }
        }
        ctrl.onClose = { [weak self] id in
            Task { @MainActor in self?.handleWindowClosed(id) }
        }
        ctrl.onInterrupt = { [weak self] id in
            Task { @MainActor in self?.handleInterrupt(id) }
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
