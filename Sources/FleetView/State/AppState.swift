import AppKit
import FleetViewAudit
import SwiftUI

/// Single source of truth for the dashboard. Owns terminal window controllers (runtime,
/// not persisted) and the persisted projects/terminals/clusters.
@MainActor
final class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var terminals: [TerminalSession] = []
    /// Terminals that have been removed, newest first. The board forgets a card the moment it is
    /// removed; this is what remembers the name, uuid and session it had (see `TerminalArchive`).
    @Published var terminalArchive: [TerminalArchive] = []
    @Published var clusters: [Cluster] = []
    @Published var selectedProjectId: UUID? = nil   // nil == All Projects
    @Published var sidebarWidth: Double = 236

    // Sidebar sections
    @Published var notes: [Note] = []
    @Published var tasksCollapsed: Bool = false
    @Published var notesCollapsed: Bool = false
    /// Show only marked terminals on the board and in the sidebar. A focus filter, not a mode: it
    /// hides cards, never touches the mark itself, and every count outside the filtered lists still
    /// speaks for the whole fleet — a fleet that is quietly half-hidden is worse than no filter.
    @Published var showOnlyMarked: Bool = false

    /// Projects whose section is folded shut on the board.
    ///
    /// Held here as a set of ids rather than as a field on `Project`, because `Project` is decoded
    /// from `state.json` and Swift's synthesized decoder does not fall back to a property's default
    /// value for a missing key — it throws. A new non-optional field on `Project` would therefore
    /// fail the whole `Persisted` decode against every state.json already on disk, and `load()`
    /// returns empty-handed on a decode failure: the entire board, gone on the next launch. The
    /// optional-field-on-Persisted shape below is what the rest of the settings use for the same
    /// reason.
    @Published var collapsedProjects: Set<UUID> = []

    /// Close every terminal when FleetView quits. Off by default, and deliberately so: sessions
    /// outliving the app is what lets a long run keep going while FleetView is updated or relaunched
    /// (see `reconnectLiveTerminals`). Turning it on makes quitting mean "stop the fleet too".
    @Published var closeTerminalsOnQuit: Bool = false

    /// Point size for terminal windows. One size for the fleet rather than one per window: cards are
    /// opened and closed constantly, so a size that lived on the window would have to be re-chosen
    /// every time — "how big is terminal text on this Mac" is a preference, not a property of a
    /// session. Pinching one window therefore settles it for all of them (on gesture end, so the
    /// other windows are not resized once per frame) and for every terminal opened afterwards.
    @Published var terminalFontSize: Double = TerminalWindowController.defaultFontSize

    /// Set once the app is tearing down. Terminal windows disappearing during a quit must not be
    /// read as the user closing a terminal, which now kills the session behind it — that would make
    /// every quit a fleet-wide kill regardless of the setting above.
    var isQuitting = false

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

    // MARK: - Conversation search (⌘K)

    @Published var searchOpen = false
    let searchModel = SearchModel()

    /// Offers a newer release when there is one (see UpdateCheck).
    let updates = UpdateCheck()

    // MARK: - Other FleetViews on the LAN
    //
    // Discovery lives in `peerFleet`; the two bits the content column switches on live here, because
    // a change published by a sub-object does not redraw a view observing AppState.

    let peerFleet = PeerFleet()
    /// nil == this Mac's own board. Set to a peer and the content column shows that machine.
    @Published var peerSelected: Peer?
    @Published var peerStripVisible = false
    /// Other machines' notes, mirrored into the sidebar list. Not persisted: they belong to those
    /// machines, and a copy surviving a relaunch would go on claiming to be current long after the
    /// machine it came from had been closed.
    @Published var peerNotes: [MirroredNote] = []
    @Published var peerNotesLoading = false
    /// The selected peer's terminals, so the sidebar's TASKS list can show that machine's work
    /// while you are looking at it. Only ever the one being viewed — holding every peer's would
    /// mean polling machines nobody is looking at.
    @Published var peerTerminals: [PeerTerminal] = []

    /// Open the switcher, scanning the first time. Deliberately not on a timer: sweeping ~760
    /// addresses in the background forever is how an app ends up looking like a port scanner.
    func togglePeerStrip() {
        peerStripVisible.toggle()
        if !peerStripVisible { peerSelected = nil; return }
        guard !peerFleet.scanned else { return }
        Task { await rescanPeers() }
    }

    func rescanPeers() async {
        let live = await peerFleet.scan()
        // A peer that went away — laptop closed, FleetView quit — must not stay selected showing a
        // page that will never load again.
        if let sel = peerSelected, !live.contains(where: { $0.id == sel.id }) { peerSelected = nil }
        await refreshPeerNotes()
    }

    /// Pull every known peer's notes into the sidebar list.
    ///
    /// Separate from the scan so it can be repeated cheaply: re-reading a handful of `/state`
    /// responses costs nothing next to sweeping a subnet, and notes are the part that actually
    /// changes while you work. Peers found in an earlier scan are reused, so the sidebar's refresh
    /// never has to sweep the network again.
    /// Turn the sidebar to a peer — or back to this Mac with nil.
    func selectPeer(_ peer: Peer?) {
        peerSelected = peer
        peerNotes = []
        peerTerminals = []
        guard peer != nil else { return }
        Task { await refreshPeerNotes() }
    }

    /// Read the selected peer's notes and terminals.
    ///
    /// Only the selected one. Reading every peer as soon as the scan found them is what put other
    /// people's notes into this machine's list uninvited — and it polled machines nobody had asked
    /// to look at. Finding a machine and going to look at it are different acts.
    func refreshPeerNotes() async {
        guard let p = peerSelected else { peerNotes = []; peerTerminals = []; return }
        peerNotesLoading = true
        defer { peerNotesLoading = false }
        guard let d = await PeerFleet.detail(for: p) else { return }   // asleep or gone: keep what we had
        peerNotes = d.notes.map {
            MirroredNote(id: "\(p.id)/\($0.id)", text: $0.text, from: p.label,
                         peerURL: p.url, noteId: $0.id)
        }
        peerTerminals = d.terminals
    }

    /// Edit a mirrored note on the machine it lives on, then re-read so the row shows what that
    /// machine actually holds rather than what we hoped it would.
    func updatePeerNote(_ note: MirroredNote, text: String) {
        Task {
            await PeerFleet.writeNote(peerURL: note.peerURL,
                                      query: ["upd": note.noteId, "text": text])
            await refreshPeerNotes()
        }
    }

    func addPeerNote(to peer: Peer, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task {
            await PeerFleet.writeNote(peerURL: peer.url, query: ["add": t])
            await refreshPeerNotes()
        }
    }

    func removePeerNote(_ note: MirroredNote) {
        Task {
            await PeerFleet.writeNote(peerURL: note.peerURL, query: ["del": note.noteId])
            await refreshPeerNotes()
        }
    }

    /// A node being dragged toward the board — from the tree panel, or from a search result.
    /// A search drag carries the hit instead of a uuid: it has to be resolved against its own
    /// project (which may have no terminal open at all), not against the tree panel's.
    struct TreeDrag {
        let nodeUuid: String
        let nativeSid: String?
        let prompt: String
        var location: CGPoint
        var hit: SearchIndex.Hit? = nil
    }
    @Published var treeDrag: TreeDrag?
    @Published var treeDropCardId: UUID?      // same-project card under the cursor → join its cluster
    @Published var treeBoardHot = false       // over the board → open standalone
    @Published var boardFrame: CGRect = .zero   // reported by MainArea; drives the inspector's placement
    /// Where each card is on screen. A list per terminal — a running card is drawn twice (see
    /// CardFramesKey), and both copies have to be droppable.
    var cardFrames: [UUID: [CGRect]] = [:]
    /// Where each cluster box is on screen (see ClusterFramesKey).
    var clusterFrames: [UUID: [CGRect]] = [:]
    /// Where each project's section is on screen (see ProjectFramesKey). A card dropped anywhere
    /// inside another project's section moves house — see `moveTerminal(_:toProject:)`.
    var projectFrames: [UUID: [CGRect]] = [:]

    /// Open the tree panel for a terminal's current session (project-dir scoped, treeflow-style).
    func openSessionTree(_ id: UUID) {
        treePanelTerminalId = id
        guard let path = transcriptPath(for: id) else {
            treeModel.showEmpty("此终端还没有 agent 会话\n发一条消息后再打开")
            return
        }
        if path.contains("/.codex/") {
            // Codex has no project directory to scope by — its rollouts are filed by date — so the
            // conversation is identified by the cwd the session itself recorded, not by the
            // terminal's, which may have moved since (see CodexTree).
            let cwd = CodexSession.rolloutCwd(path)
                ?? terminals.first { $0.id == id }?.cwd ?? ""
            guard !cwd.isEmpty else {
                treeModel.showEmpty("读不出这个 Codex 会话的工作目录")
                return
            }
            treeModel.open(source: .codex(cwd: cwd),
                           boundSessionId: CodexTree.sessionId(fromRollout: path),
                           sessions: codexSessionsInfo(cwd: cwd))
            return
        }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let sid = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        treeModel.open(source: .claude(projectDir: dir), boundSessionId: sid,
                       sessions: treeSessionsInfo(projectDir: dir))
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

    /// sid → terminals sitting on that Codex session. Scoped by the cwd the ROLLOUT recorded, which
    /// is what CodexTree groups by — a terminal that cd'd elsewhere still belongs to its session.
    private func codexSessionsInfo(cwd: String) -> [String: [(name: String, status: TermStatus)]] {
        var out: [String: [(String, TermStatus)]] = [:]
        for t in terminals {
            guard let p = transcriptPath(for: t.id), p.contains("/.codex/"),
                  CodexSession.rolloutCwd(p) == cwd else { continue }
            out[CodexTree.sessionId(fromRollout: p), default: []].append((t.name, t.status))
        }
        return out
    }

    /// Keep the panel's terminal chips truthful as statuses/sessions move.
    func refreshTreeChips() {
        guard treePanelTerminalId != nil, let source = treeModel.source else { return }
        switch source {
        case .claude(let dir): treeModel.updateSessions(treeSessionsInfo(projectDir: dir))
        case .codex(let cwd):  treeModel.updateSessions(codexSessionsInfo(cwd: cwd))
        }
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
            entry.value.contains { $0.contains(location) }
                && terminals.first(where: { $0.id == entry.key })?.projectId == srcProject
                && entry.key != treePanelTerminalId   // dropping back onto the source card means "cluster with it" too — allow
        }?.key ?? cardFrames.first { entry in
            entry.value.contains { $0.contains(location) }
                && terminals.first(where: { $0.id == entry.key })?.projectId == srcProject
        }?.key
        treeDropCardId = card
        treeBoardHot = card == nil && boardFrame.contains(location)
    }

    /// A search result being dragged. Drop targets are scoped to the hit's OWN project — joining
    /// a cluster in some unrelated project would put the conversation in the wrong place.
    func searchDragChanged(hit: SearchIndex.Hit, location: CGPoint) {
        let prompt = hit.body.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if treeDrag?.hit?.id == hit.id {
            treeDrag?.location = location
        } else {
            treeDrag = TreeDrag(nodeUuid: hit.node, nativeSid: nil, prompt: prompt,
                                location: location, hit: hit)
        }
        let card = cardFrames.first { entry in
            entry.value.contains { $0.contains(location) }
                && project(terminals.first(where: { $0.id == entry.key })?.projectId)?.path == hit.project
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
        guard let d = drag, card != nil || boardHot else { return }
        if let hit = d.hit {
            // Resolving a hit reads transcripts and may synthesise a fork, so it runs off the main
            // actor; the model owns that path (and the spinner) already.
            searchModel.open(hit, in: self, joinClusterOf: card)
        } else if let card {
            forkOpenNode(nodeUuid: d.nodeUuid, nativeSid: d.nativeSid, prompt: d.prompt, joinClusterOf: card)
        } else {
            forkOpenNode(nodeUuid: d.nodeUuid, nativeSid: d.nativeSid, prompt: d.prompt, joinClusterOf: nil)
        }
    }

    // MARK: Fork-open (tree node → new terminal)

    /// Open a new terminal resuming the given node: native sessions resume directly, everything else
    /// gets a synthesized fork file (treeflow's algorithm — the original session is never modified).
    func forkOpenNode(nodeUuid: String, nativeSid: String?, prompt: String, joinClusterOf targetCard: UUID?) {
        guard let srcId = treePanelTerminalId,
              let src = terminals.first(where: { $0.id == srcId }),
              let source = treeModel.source else { return }

        var clusterId: UUID?
        if let target = targetCard { clusterId = ensureCluster(for: target) }

        let shortPrompt = prompt.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = "⑂ " + String(shortPrompt.prefix(12))
        guard let newT = newTerminal(projectId: src.projectId, name: name,
                                     clusterId: clusterId, autoRunClaude: false) else { return }
        let createdAt = Date()

        // Codex nodes are addressed as treeflow addresses them (CodexTree), so opening one is the
        // same call the search panel already makes for a Codex hit — there is no second copy of
        // that logic here, and none of SessionForge's Claude-shaped fork synthesis applies.
        if case .codex(let cwd) = source {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let plan = try SearchOpen.planCodexNode(node: nodeUuid, cwd: cwd, label: name)
                    Task { @MainActor in
                        guard let self else { return }
                        FV.log("tree fork: \(plan.detail)")
                        let elapsed = Date().timeIntervalSince(createdAt)
                        self.typeIntoTerminal(newT.id, plan.command, after: max(0.2, 1.4 - elapsed))
                    }
                } catch {
                    Task { @MainActor in
                        // Loud, unlike the Claude path's log line: the only way this fails in
                        // practice is treeflow missing, and the fix is one pip command the error
                        // itself spells out — silence would leave a terminal sitting at a bare
                        // prompt with no idea why.
                        FV.log("tree fork FAILED (codex): \(error.localizedDescription)")
                        let a = NSAlert()
                        a.messageText = "打不开这个 Codex 节点"
                        a.informativeText = error.localizedDescription
                        a.runModal()
                    }
                }
            }
            return
        }
        guard let dir = treeModel.projectDir else { return }

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
                // The fork file was written into `dir`, so the terminal has to start somewhere whose
                // project slug IS `dir` — `--resume` searches by the current directory's slug, and a
                // recorded `cwd` is often a subdirectory the agent cd'd into, which lands under a
                // different slug and answers "No conversation found".
                let recorded = SessionForge.sessionCwd(
                    transcriptPath: dir.appendingPathComponent("\(fork.sessionId).jsonl").path)
                    ?? SessionForge.sessionCwd(transcriptPath: srcTranscript ?? "")
                let sessionCwd = (recorded.map {
                    SessionForge.slugify($0) == dir.lastPathComponent
                } == true) ? recorded : (SessionForge.projectCwd(projectDir: dir) ?? recorded)
                let cmd = SessionForge.resumeCommand(sessionId: fork.sessionId, inheritedFlags: flags,
                                                     skipPermissions: true,
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
    func typeIntoTerminal(_ id: UUID, _ command: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.controllers[id]?.type(command + "\r")
        }
    }

    /// The terminal's cluster, creating one (named after it) when it has none — shared by
    /// duplicate, tree-drop-on-card and search-drop-on-card.
    func ensureCluster(for id: UUID) -> UUID? {
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
    /// A Codex status refresh is out on a background queue. Not @Published — nothing draws it, and
    /// a flag that re-renders the board every second would undo the point of moving the work off.
    private var codexRefreshInFlight = false
    /// The pending debounced save (see `save()`).
    private var saveWork: DispatchWorkItem?

    /// Watch `~/.fleetview/ui/panel.html` so an agent can create / update / remove the panel *while*
    /// FleetView runs — it appears, reloads and disappears live, no relaunch. The polling lives here
    /// rather than in the view because a SwiftUI view that currently renders nothing (no panel yet)
    /// never receives timer events, which would make the panel appear only after a restart.
    func startPanelWatch() {
        try? FileManager.default.createDirectory(at: FV.uiDir, withIntermediateDirectories: true)
        refreshPanel()
        panelTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPanel()
                self?.refreshCodexStatus()
            }
        }
        RunLoop.main.add(t, forMode: .common)   // keep ticking during menu tracking / scrolling
        panelTimer = t
    }

    /// Codex terminals get their status from their rollout, because no Codex hook ever fires (see
    /// CodexSession). Without this they sat on `idle` no matter what they were doing — a card that
    /// says idle while the agent is mid-turn is worse than no status at all, and it is also what
    /// made the web chat look unresponsive: you send, nothing changes, and the reply only appears
    /// when the transcript catches up.
    ///
    /// Only `working` and `idle` are decided here. `needsYou` comes from the screen, which is the
    /// only place an approval prompt shows up, and is left alone.
    /// Every second, and every part of it is file I/O — so none of it runs here. Measured on this
    /// fleet before it was moved: resolving each Codex terminal's rollout walked ~2000 files, and
    /// reading the 256KB tail to find the last turn boundary cost another 4ms; 44ms of main-actor
    /// time per second, three dropped frames a second, for a poll that usually changes nothing.
    /// That was the board "getting laggy once there are a lot of terminals".
    ///
    /// The main actor now only snapshots what the resolve needs and applies the answer. The `claimed`
    /// set and the fallback order are the Codex half of `transcriptPath(for:)`, kept in step with it
    /// deliberately: rollout first (a hook pointer goes stale and stays stale), then the pointer,
    /// then whatever was last recorded.
    private func refreshCodexStatus() {
        guard !codexRefreshInFlight else { return }   // a slow disk must not queue these up
        let targets = terminals.filter {
            $0.agentKind == .codex && $0.status != .closed && $0.status != .needsYou
        }.map { t in
            (id: t.id, cwd: t.cwd, hook: hookSessionPath(for: t.id), stored: t.transcriptPath)
        }
        guard !targets.isEmpty else { return }
        let claimed = Set(terminals.compactMap { $0.transcriptPath })
        codexRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var verdicts: [(UUID, Bool)] = []
            for t in targets {
                let path = CodexSession.currentRollout(cwd: t.cwd,
                                                       excluding: claimed.subtracting([t.stored].compactMap { $0 }))
                    ?? t.hook ?? t.stored
                guard let path, let working = CodexSession.isWorking(rollout: path) else { continue }
                verdicts.append((t.id, working))
            }
            Task { @MainActor in
                guard let self else { return }
                self.codexRefreshInFlight = false
                for (id, working) in verdicts {
                    guard let i = self.terminals.firstIndex(where: { $0.id == id }) else { continue }
                    // Re-check the guard: this is one poll behind now, and the terminal may have
                    // been closed or raised a prompt while the disk was being read.
                    guard self.terminals[i].status != .closed, self.terminals[i].status != .needsYou else { continue }
                    let next: TermStatus = working ? .working : .idle
                    if self.terminals[i].status != next { self.enterStatus(next, at: i) }
                }
            }
        }
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
        var projects: [Project] = []
        var terminals: [TerminalSession] = []
        var clusters: [Cluster] = []
        var selectedProjectId: UUID?
        var sidebarWidth: Double?
        var notes: [Note]?
        var tasksCollapsed: Bool?
        var notesCollapsed: Bool?
        var treePanelWidth: Double?
        var showOnlyMarked: Bool?
        var closeTerminalsOnQuit: Bool?
        var collapsedProjects: [UUID]?
        var terminalFontSize: Double?
        var terminalArchive: [TerminalArchive]?

        /// Every field decoded on its own, and a field that will not decode is dropped rather than
        /// taken as a corrupt file.
        ///
        /// This is not defensive tidiness. Synthesised `Codable` treats a missing key as an error
        /// even for a property with a default, so adding one non-optional field to a struct already
        /// on disk made the whole of `Persisted` fail to decode — and `load()`, seeing no decodable
        /// state, started from nothing and saved that over every project, terminal and note the
        /// file held. One new field cost the entire board. The blast radius of a schema slip
        /// belongs to the field that slipped.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func get<T: Decodable>(_ k: CodingKeys, _ t: T.Type) -> T? {
                (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil
            }
            projects = get(.projects, [Project].self) ?? []
            terminals = get(.terminals, [TerminalSession].self) ?? []
            clusters = get(.clusters, [Cluster].self) ?? []
            selectedProjectId = get(.selectedProjectId, UUID.self)
            sidebarWidth = get(.sidebarWidth, Double.self)
            notes = get(.notes, [Note].self)
            tasksCollapsed = get(.tasksCollapsed, Bool.self)
            notesCollapsed = get(.notesCollapsed, Bool.self)
            treePanelWidth = get(.treePanelWidth, Double.self)
            showOnlyMarked = get(.showOnlyMarked, Bool.self)
            closeTerminalsOnQuit = get(.closeTerminalsOnQuit, Bool.self)
            collapsedProjects = get(.collapsedProjects, [UUID].self)
            terminalFontSize = get(.terminalFontSize, Double.self)
            terminalArchive = get(.terminalArchive, [TerminalArchive].self)
        }

        init(projects: [Project], terminals: [TerminalSession], clusters: [Cluster],
             selectedProjectId: UUID?, sidebarWidth: Double?, notes: [Note]?,
             tasksCollapsed: Bool?, notesCollapsed: Bool?, treePanelWidth: Double?,
             showOnlyMarked: Bool?, closeTerminalsOnQuit: Bool?, collapsedProjects: [UUID]?,
             terminalFontSize: Double?, terminalArchive: [TerminalArchive]?) {
            self.projects = projects; self.terminals = terminals; self.clusters = clusters
            self.selectedProjectId = selectedProjectId; self.sidebarWidth = sidebarWidth
            self.notes = notes; self.tasksCollapsed = tasksCollapsed
            self.notesCollapsed = notesCollapsed; self.treePanelWidth = treePanelWidth
            self.showOnlyMarked = showOnlyMarked; self.closeTerminalsOnQuit = closeTerminalsOnQuit
            self.collapsedProjects = collapsedProjects; self.terminalFontSize = terminalFontSize
            self.terminalArchive = terminalArchive
        }
    }

    /// A first run — no `state.json` at all — opens the checkout this bundle was built from, so a
    /// fresh install lands on something instead of an empty board. `package_app.sh` records the path
    /// as `FVSourceRepo`, since the copy in /Applications has no other way to know where it came from.
    ///
    /// Keyed on the file being *absent*, not on `projects` being empty: someone who deliberately
    /// removes every project would otherwise be handed FleetView back at every launch.
    private func seedFirstProject() {
        guard let repo = Bundle.main.object(forInfoDictionaryKey: "FVSourceRepo") as? String,
              !repo.isEmpty else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo, isDirectory: &isDir), isDir.boolValue
        else { return }   // the checkout was moved or deleted since packaging
        addProject(path: repo)
    }

    func load() {
        FV.ensureSupportDir()
        guard let data = try? Data(contentsOf: FV.stateFile),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else {
            seedFirstProject()
            return
        }
        projects = p.projects
        terminals = p.terminals.map { row in
            var t = row
            t.status = .closed        // live processes are gone after a relaunch
            t.runningSince = nil      // …so any run clock stored with them is meaningless now
            t.sessionId = nil
            return t                   // keep transcriptPath so we can rebuild the token curve
        }
        clusters = p.clusters
        // Rows without a transcript predate the rule that stopped recording shell-only cards.
        // Dropped on the way in rather than filtered forever, so the stored file converges too.
        terminalArchive = (p.terminalArchive ?? []).filter { $0.transcriptPath != nil }
        // Re-attach rows written before the path was recorded. Their project id may already be
        // dead — closing and reopening a folder mints a new one — so they are matched by the
        // deepest project their terminal's cwd sits inside, which is where that terminal ran.
        for i in terminalArchive.indices where (terminalArchive[i].projectPath ?? "").isEmpty {
            let cwd = terminalArchive[i].cwd
            let owner = projects
                .filter { !$0.path.isEmpty && (cwd == $0.path || cwd.hasPrefix($0.path + "/")) }
                .max { $0.path.count < $1.path.count }
            if let owner { terminalArchive[i].projectPath = owner.path }
        }
        selectedProjectId = p.selectedProjectId
        if let w = p.sidebarWidth { sidebarWidth = min(520, max(180, w)) }
        notes = p.notes ?? []
        tasksCollapsed = p.tasksCollapsed ?? false
        notesCollapsed = p.notesCollapsed ?? false
        showOnlyMarked = p.showOnlyMarked ?? false
        closeTerminalsOnQuit = p.closeTerminalsOnQuit ?? false
        // Clamped on the way in as well as on the way out: state.json is a file on disk that people
        // do edit, and a 400pt terminal is a window with one character in it.
        if let s = p.terminalFontSize {
            terminalFontSize = min(TerminalWindowController.fontSizeRange.upperBound,
                                   max(TerminalWindowController.fontSizeRange.lowerBound, s))
        }
        // Intersected with what actually exists: a project removed while collapsed would otherwise
        // leave its id here forever, and if a future one were ever created with that id it would
        // open folded for no reason anybody could explain.
        collapsedProjects = Set(p.collapsedProjects ?? []).intersection(projects.map(\.id))
        if let w = p.treePanelWidth { treePanelWidth = min(720, max(380, w)) }
        // Rebuild each terminal's token curve from its transcript (background; badge shows meanwhile).
        for t in terminals { if let tp = t.transcriptPath { refreshTokens(t.id, path: tp) } }
    }

    /// Persist soon, not now.
    ///
    /// Every hook event ends in a save, and a save is a JSONEncoder pass over the whole model plus a
    /// 20KB write — on the main actor, in the middle of a burst of events, while you are scrolling.
    /// Nothing reads this file until the next launch, so the only real requirements are "soon" and
    /// "definitely before we quit"; `saveNow()` is the second one and is called from
    /// applicationWillTerminate.
    func save() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        FV.ensureSupportDir()
        let snapshot = terminals.map { t -> TerminalSession in
            var c = t
            if controllers[t.id] == nil { c.status = .closed; c.runningSince = nil }
            return c
        }
        let p = Persisted(projects: projects, terminals: snapshot,
                          clusters: clusters, selectedProjectId: selectedProjectId,
                          sidebarWidth: sidebarWidth, notes: notes,
                          tasksCollapsed: tasksCollapsed, notesCollapsed: notesCollapsed,
                          treePanelWidth: treePanelWidth, showOnlyMarked: showOnlyMarked,
                          closeTerminalsOnQuit: closeTerminalsOnQuit,
                          collapsedProjects: Array(collapsedProjects),
                          terminalFontSize: terminalFontSize,
                          terminalArchive: terminalArchive)
        // .atomic: without it a crash or a full disk mid-write leaves a truncated state.json, and
        // that file IS the board — every project, terminal and cluster.
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: FV.stateFile, options: .atomic) }
    }

    // MARK: - Projects

    func addProject(path: String) {
        let url = URL(fileURLWithPath: path)
        let id: UUID
        if let existing = projects.first(where: { $0.path == path }) {
            selectedProjectId = existing.id
            id = existing.id
        } else {
            let isGit = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
            let proj = Project(name: url.lastPathComponent, path: path, isGit: isGit)
            projects.append(proj)
            selectedProjectId = proj.id
            id = proj.id
        }
        // Take the board to it. A new project is appended, so it lands at the very bottom — past
        // however many sections are already open — and opening a folder that then appears nowhere
        // on screen reads as nothing having happened. Deferred by one turn so the section exists
        // to scroll to: `scrollToId` is consumed by MainArea's `onChange`, which fires as this
        // mutation lands, before the new ProjectSection has been built. Cleared first so opening a
        // folder that is already on the board still counts as a change and still scrolls.
        scrollToId = nil
        DispatchQueue.main.async { [weak self] in self?.scrollToId = id }
        save()
    }

    /// Clone a repository onto the board without holding anything up.
    ///
    /// The sheet closes the moment this is called. A clone is minutes of network on a machine whose
    /// whole job is watching agents run, and behind a modal sheet those minutes were minutes of
    /// FleetView being unusable — including the board, the terminals and the fleet the clone has
    /// nothing to do with. Everything after the start is reported by the job row, failures included:
    /// the sheet that used to show them is no longer on screen by the time git gets round to them.
    func cloneRepository(_ repo: String, into parentDir: String) {
        let jobs = BackgroundJobs.shared
        let id = jobs.start(.clone, title: "克隆 \(Git.repoName(from: repo))", detail: "准备中…")
        let task = Task { [weak self] in
            do {
                let dest = try await Git.clone(repo: repo, into: parentDir) { fraction, line in
                    Task { @MainActor in jobs.progress(id, fraction, line) }
                }
                self?.addProject(path: dest)
                jobs.finish(id, dest)
            } catch is CancellationError {
                // The row went the moment ✕ was pressed, and Git.clone has already swept up the
                // half-written directory. Nothing left to say.
            } catch {
                jobs.fail(id, error.localizedDescription, recoverLabel: "重试") {
                    BackgroundJobs.shared.dismiss(id)
                    self?.cloneRepository(repo, into: parentDir)
                }
            }
        }
        jobs.setCancel(id) { task.cancel() }
    }

    func project(_ id: UUID?) -> Project? { projects.first { $0.id == id } }

    /// The project whose section is currently being dragged on the board (nil when none is).
    /// A system drag has no "cancelled" callback, so a stranded value has to stay harmless: it is
    /// only ever read together with a live drop, and the next drag overwrites it.
    @Published var draggingProjectId: UUID?

    /// Reorder the board: put `id` where `target` sits now. `projects` is the only ordering there
    /// is — the board sections and the sidebar's task groups both iterate it — so this moves both.
    /// Runs mid-drag (the board rearranges under the cursor), hence idempotent on repeat hovers.
    func moveProject(_ id: UUID, onto target: UUID) {
        guard id != target,
              let from = projects.firstIndex(where: { $0.id == id }),
              let to = projects.firstIndex(where: { $0.id == target }) else { return }
        let p = projects.remove(at: from)
        projects.insert(p, at: to)
        save()
    }

    func removeProject(_ id: UUID) {
        for t in terminals.filter({ $0.projectId == id }) { removeTerminal(t.id) }
        projects.removeAll { $0.id == id }
        if selectedProjectId == id { selectedProjectId = nil }
        collapsedProjects.remove(id)
        save()
    }

    /// Fold a project's section shut, hiding its cards behind its header.
    ///
    /// A view-only fold: it hides cards, it does not touch a terminal or what it is doing, and every
    /// count outside the section still speaks for the whole fleet. Same rule as the mark filter —
    /// a board that is quietly hiding work is worse than one that is not hiding any.
    func toggleProjectCollapsed(_ id: UUID) {
        if collapsedProjects.contains(id) { collapsedProjects.remove(id) }
        else { collapsedProjects.insert(id) }
        save()
    }

    func isCollapsed(_ id: UUID) -> Bool { collapsedProjects.contains(id) }

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

    /// Reopen a closed terminal — and put it back into the conversation it was in.
    ///
    /// Closing a terminal now really closes it, so a card left on the board is a session that
    /// exists only as a transcript. Clicking it has to mean "carry on where we were": a fresh
    /// `claude` that has forgotten the last two hours is a worse answer than not reopening at all.
    /// A session that is still alive (FleetView was relaunched, the tmux session outlived it) is
    /// reattached instead, and nothing is typed — that terminal already has its agent.
    func reopenTerminal(_ id: UUID) {
        if controllers[id] != nil { raiseTerminal(id); return }
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        let t = terminals[idx]
        let resumeFrom = remote.sessionExists(id) ? nil : lastSessionFile(for: t)
        enterStatus(.shell, at: idx)
        // Suppress the automatic `claude` only when there is something to resume — otherwise a
        // terminal that never ran an agent would come back as a bare shell.
        openWindow(for: t, autoRun: resumeFrom == nil ? nil : false)
        if let path = resumeFrom { resumeSession(t, transcript: path) }
        save()
    }

    /// The transcript this card last had, and the one a reopen must resume.
    ///
    /// Deliberately not `transcriptPath(for:)`: that falls back to the newest unclaimed session in
    /// the cwd, which is a fine guess for a *live* terminal and a bad one here — for a closed card
    /// it is as likely to be a conversation some other terminal started since.
    func lastSessionFile(for t: TerminalSession) -> String? {
        if let p = hookSessionPath(for: t.id) { return p }
        if let p = t.transcriptPath, FileManager.default.fileExists(atPath: p) { return p }
        return nil
    }

    /// Work out the resume command off the main actor (it reads transcripts and can walk the
    /// filesystem looking for the session's project folder), then type it into the fresh shell.
    private func resumeSession(_ t: TerminalSession, transcript path: String,
                               pinnedCwd: String? = nil) {
        let createdAt = Date()
        let kind = t.agentKind
        let termCwd = t.cwd
        let id = t.id
        let name = t.name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let cmd = AppState.resumeCommand(transcript: path, kind: kind, termCwd: termCwd,
                                                   pinnedCwd: pinnedCwd) else {
                FV.log("reopen: nothing resumable for \(name) (\(path))")
                return
            }
            Task { @MainActor in
                guard let self else { return }
                FV.log("reopen: resuming \(name) — \(cmd)")
                // Same handoff as the fork paths: the shell (and, under tmux, the session) needs a
                // moment to be ready before it can be typed into.
                let elapsed = Date().timeIntervalSince(createdAt)
                self.typeIntoTerminal(id, cmd, after: max(0.2, 1.4 - elapsed))
            }
        }
    }

    /// `claude --resume <sid>` / `codex resume <sid>` for a transcript on disk, with the `cd` that
    /// makes it resolve. Pure and off-actor: it only touches the filesystem.
    /// `codex resume <id>` or `codex fork <id>` for a rollout, run from the cwd it was recorded in.
    ///
    /// One function for both verbs so the two cannot drift: a rollout is named
    /// `rollout-<timestamp>-<uuid>.jsonl` and the CLI wants the UUID alone — handing it the whole
    /// filename opens the session picker instead, which looks like the command being ignored.
    nonisolated static func codexCommand(transcript path: String, termCwd: String,
                                         verb: String, pinnedCwd: String? = nil) -> String? {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let parts = base.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        let sid = parts.suffix(5).joined(separator: "-")
        guard UUID(uuidString: sid) != nil else { return nil }
        // The rollout says where the session ran, which is the right answer everywhere except
        // after a deliberate move — there the card has been told it belongs somewhere else, and
        // `cd`-ing back into the project it just left would undo the gesture.
        let cwd = pinnedCwd ?? CodexSession.rolloutCwd(path) ?? termCwd
        let cmd = "codex \(verb) \(sid)"
        return cwd == termCwd ? cmd : "cd \(SessionForge.shellQuote(cwd)) && \(cmd)"
    }

    nonisolated static func resumeCommand(transcript path: String, kind: AgentKind,
                                          termCwd: String, pinnedCwd: String? = nil) -> String? {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !base.isEmpty else { return nil }

        if kind == .codex || path.contains("/.codex/") {
            return codexCommand(transcript: path, termCwd: termCwd, verb: "resume",
                                pinnedCwd: pinnedCwd)
        }

        // Claude resolves `--resume <sid>` against the *current* folder's project slug, so the
        // terminal has to start somewhere that slugifies to the directory the transcript is filed
        // under — the session's own recorded cwd is often a subdirectory the agent cd'd into, which
        // lands under a different slug and answers "No conversation found". Same rule as the fork
        // paths, and the reason this is worth a filesystem walk.
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let recorded = SessionForge.sessionCwd(transcriptPath: path)
        // `pinnedCwd` is only ever passed by a caller that has just filed this transcript under
        // that folder's slug itself, so it needs none of the searching below.
        let cwd = pinnedCwd
            ?? ((recorded.map { SessionForge.slugify($0) == dir.lastPathComponent } == true)
                ? recorded : (SessionForge.projectCwd(projectDir: dir) ?? recorded))
        // `skipPermissions`, like every other path that reopens an existing conversation: the flags
        // the original process ran with died with it (`inheritedFlags` reads a live process tree),
        // so without this a resumed terminal stops on its first tool call — asking permission for
        // work the session was already trusted to do.
        return SessionForge.resumeCommand(sessionId: base, inheritedFlags: [],
                                          skipPermissions: true,
                                          cwd: cwd == termCwd ? nil : cwd)
    }

    /// Move a terminal into another project — folder, conversation and all.
    ///
    /// Dragging a card onto a different project's section is a statement about where this work
    /// belongs, and the folder it opens in is only half of it. Claude files a transcript under a
    /// slug of the directory it ran in and `--resume` looks it up the same way (see
    /// `resumeCommand`), so a card whose cwd moved while its transcript stayed behind is a card
    /// that can never resume its own conversation again. The file moves with it.
    ///
    /// Codex has no such link — rollouts are filed by date, not by project — so there is nothing to
    /// move there. What does have to be corrected is the folder `codex resume` would otherwise `cd`
    /// back into: the rollout records where it ran, which is the project this card just left.
    ///
    /// The session is killed and reopened rather than carried across. A running agent holds an open
    /// handle on the transcript and a cwd of its own, and neither of those follows a rename — the
    /// conversation comes back because it is resumed, not because the process survived.
    func moveTerminal(_ id: UUID, toProject target: UUID) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }),
              let project = projects.first(where: { $0.id == target }),
              terminals[idx].projectId != target else { return }
        audited(AuditIntent("terminal.move_project",
                            categories: ["configuration"],
                            target: auditTarget(terminal: id),
                            data: ["to": .string(project.name), "cwd": .string(project.path)],
                            message: "moved to \(project.name)")) {
            let was = terminals[idx]
            // Resolved before anything is torn down: a running agent's transcript is known from the
            // hook pointer, and the kill below is what stops that pointer being written.
            //
            // `lastSessionFile`, deliberately, and not `transcriptPath(for:)` — that one falls back
            // to the newest unclaimed session in the folder, which is a reasonable guess for
            // *reading* a live terminal and an unacceptable one here. This path moves a file; a
            // wrong guess would carry somebody else's conversation into another project.
            let transcript = lastSessionFile(for: was)
            let live = controllers[id] != nil || remote.sessionExists(id)
            let isCodex = was.agentKind == .codex || transcript?.contains("/.codex/") == true

            // We own the status from here. `onClose` fires on the next main-actor turn — after the
            // reopen below — and would mark a terminal that is on screen as closed.
            let ctrl = controllers.removeValue(forKey: id)
            ctrl?.onClose = nil
            ctrl?.closeWindow()
            remote.stop(id)

            let moved = isCodex ? nil : transcript.flatMap { relocateTranscript($0, to: project.path) }
            if let moved { rewriteSessionPointer(id, transcript: moved, cwd: project.path) }

            terminals[idx].projectId = target
            terminals[idx].cwd = project.path
            // A cluster is a group inside one project — `clustersInProject` places a cluster by its
            // members — so a card that leaves the project leaves the group with it.
            terminals[idx].clusterId = nil
            if let moved { terminals[idx].transcriptPath = moved }

            let resumeFrom = moved ?? transcript
            // Reopened even when the card was already closed: the drag said this work belongs over
            // there, and a card that answers by staying dark gives no sign the conversation
            // survived the trip. Nothing to reopen for a card that never ran anything.
            let reopen = live || resumeFrom != nil
            enterStatus(reopen ? .shell : .closed, at: idx)
            pruneClusters()
            save()
            guard reopen else { return }

            openWindow(for: terminals[idx], autoRun: resumeFrom == nil ? nil : false)
            if let resumeFrom {
                // Pin the new folder only where it is true. Codex resumes from anywhere, so the
                // move is the newer statement of where this work belongs. Claude resolves against
                // the current folder's slug, so pinning is honest exactly when the transcript
                // actually landed under it — if the move failed, the conversation still lives in
                // the old project and resuming it there beats not resuming at all.
                resumeSession(terminals[idx], transcript: resumeFrom,
                              pinnedCwd: (isCodex || moved != nil) ? project.path : nil)
            }
        }
    }

    /// Move a Claude transcript into the project its terminal just moved to; returns where it
    /// landed, or nil when there was nothing to move or the move failed.
    ///
    /// The destination is the slug of the new folder because that is the only place `--resume` will
    /// ever look. A file already sitting there is left alone rather than overwritten: the same
    /// session id under two projects should be impossible, and if it ever happens the file already
    /// there is somebody's conversation.
    private func relocateTranscript(_ path: String, to projectPath: String) -> String? {
        let src = URL(fileURLWithPath: path)
        guard src.pathExtension == "jsonl", path.contains("/.claude/projects/") else { return nil }
        let dir = FV.claudeProjectsDir
            .appendingPathComponent(SessionForge.slugify(projectPath), isDirectory: true)
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        guard dest.path != src.path else { return src.path }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: dest.path) else {
                FV.log("move: \(dest.path) already exists — transcript left where it was")
                return nil
            }
            try FileManager.default.moveItem(at: src, to: dest)
        } catch {
            FV.log("move: could not move transcript — \(error.localizedDescription)")
            return nil
        }
        // Search keys conversations by path, so without this the one conversation becomes two: a
        // dead hit at the old path, whose file is gone, and a fresh read of the same messages at
        // the new one.
        SearchIndex.relocate(from: src.path, to: dest.path, project: projectPath)
        FV.log("move: transcript \(src.lastPathComponent) → \(dir.lastPathComponent)")
        return dest.path
    }

    /// Keep hook.sh's pointer pointing at the transcript after it moves.
    ///
    /// A stale pointer is survivable — `hookSessionPath` drops one whose file is gone — but it is
    /// what every reader asks first, and the next hook event is a whole turn away.
    private func rewriteSessionPointer(_ id: UUID, transcript: String, cwd: String) {
        let url = FV.sessionPointer(for: id)
        guard let data = try? Data(contentsOf: url),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        obj["transcript_path"] = transcript
        obj["cwd"] = cwd
        // Edited rather than rewritten: hook.sh puts the whole event in here — permission mode,
        // last message, background tasks — and this knows about two of those keys.
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? out.write(to: url, options: .atomic)
    }

    /// Terminals with a window open right now — what "close all" would actually close.
    var openTerminalCount: Int { terminals.filter { $0.status.isOpen }.count }

    /// Close every terminal: the windows go away and the agents behind them stop for real.
    ///
    /// The cards stay on the board, which is what makes this recoverable rather than destructive —
    /// clicking one reopens it and resumes the conversation it was in (see `reopenTerminal`).
    @discardableResult
    func closeAllTerminals(reason: String) -> Int {
        let open = openTerminalCount
        let live = remote.available ? remote.liveSessions().count : 0
        guard open > 0 || live > 0 else { return 0 }
        let count = max(open, live)
        audited(AuditIntent("terminal.close_all",
                            event: "fleetview.terminals.closed_all",
                            categories: ["process"],
                            data: ["terminals": .int(count), "reason": .string(reason)],
                            message: "closed all terminals (\(reason))")) {
            // Drop the controllers *first*: that is also how `handleWindowClosed` is told to skip
            // its per-terminal kill, so the whole fleet costs one `kill-server` rather than one
            // tmux invocation per card.
            let ctrls = controllers
            controllers.removeAll()
            for (_, c) in ctrls { c.closeWindow() }
            remote.killAllSessions()
            for i in terminals.indices where terminals[i].status != .closed {
                enterStatus(.closed, at: i)
            }
            FV.log("closed all terminals (\(reason)): \(count)")
            save()
        }
        return count
    }

    /// Empty the board: every terminal closed, every project and cluster gone.
    ///
    /// The one action here that cannot be undone by dragging something back. `closeAllTerminals`
    /// leaves the cards behind precisely so a closed terminal can be reopened into its conversation;
    /// this throws those cards away, along with the names, marks and cluster structure that only
    /// ever existed in `state.json`. The conversations themselves are untouched — they live in the
    /// agents' own transcripts, and ⌘K still finds every one of them — so what is lost is the board,
    /// not the work. Callers confirm first.
    func clearBoard(reason: String) {
        audited(AuditIntent("board.clear",
                            event: "fleetview.board.cleared",
                            categories: ["configuration"],
                            data: ["projects": .int(projects.count),
                                   "terminals": .int(terminals.count),
                                   "reason": .string(reason)],
                            message: "cleared the board (\(reason))")) {
            closeSessionTree()
            // Nested audit on purpose: the process teardown is attributed to `terminal.close_all`
            // and only what is left — the removals — lands under this intent.
            closeAllTerminals(reason: reason)
            FV.log("board cleared (\(reason)): \(projects.count) project(s), \(terminals.count) terminal(s)")
            terminals.removeAll()
            projects.removeAll()
            clusters.removeAll()
            // The per-terminal caches are keyed by an id that no longer exists; left behind they
            // would be a slow leak across a long-running app.
            tokenSeries.removeAll()
            lastParsedTranscriptSize.removeAll()
            lastTokenRefreshAt.removeAll()
            selectedProjectId = nil
            highlightedTerminalId = nil
            highlightedClusterId = nil
            save()
        }
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
                enterStatus(t.agentKind != .unknown ? .idle : .shell, at: i)
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

        let livePath = !blank ? (hookSessionPath(for: id) ?? src.transcriptPath) : nil
        let onDisk = livePath.map { FileManager.default.fileExists(atPath: $0) } == true

        // Codex forks natively now, and a duplicate is exactly the case it covers — a branch from
        // the tip. This used to be excluded, back when it could not, and the exclusion outlived the
        // reason: duplicating a Codex card silently handed you an empty terminal. (Branching from a
        // turn in the *middle* is still treeflow's synthesised rollout; `codex fork` has no way to
        // land on one.)
        if let path = livePath, onDisk, path.contains("/.codex/"),
           let cmd = Self.codexCommand(transcript: path, termCwd: src.cwd, verb: "fork") {
            guard let newT = newTerminal(projectId: src.projectId, name: src.name + " ⑂",
                                         clusterId: clusterId, autoRunClaude: false) else { return }
            if let idx = terminals.firstIndex(where: { $0.id == newT.id }) {
                terminals[idx].agentKind = .codex
            }
            typeIntoTerminal(newT.id, cmd, after: 1.4)
            return
        }

        var forkSid: String?
        if let path = livePath, onDisk, !path.contains("/.codex/") {
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

    /// How many removed terminals a project keeps. Old enough entries stop being something you are
    /// looking for and start being weight in state.json, which is rewritten on every hook event.
    static let archiveCap = 200

    private func removeTerminalUnaudited(_ id: UUID) {
        // Archive before anything is torn down — `transcriptPath(for:)` needs the terminal to still
        // be in `terminals`, and after this line the session id is unrecoverable.
        if let t = terminals.first(where: { $0.id == id }) { archive(t) }
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

    /// Record a terminal on its way out.
    ///
    /// The transcript is resolved here rather than trusted from the card: a terminal that ran an
    /// agent may never have had `transcriptPath` written back, and once the row is gone there is no
    /// second chance to look. Same id every time, so removing a restored terminal updates its row
    /// instead of leaving two claiming to be the same uuid.
    private func archive(_ t: TerminalSession) {
        // A card that only ever held a shell has nothing to come back to — no transcript, nothing
        // to resume, nothing to read. Keeping those rows would fill the drawer with entries whose
        // only possible answer is "shell only", and push out the ones you would actually reopen.
        guard let transcript = t.transcriptPath ?? lastSessionFile(for: t) else { return }
        let entry = TerminalArchive(id: t.id, projectId: t.projectId,
                                    projectPath: project(t.projectId)?.path,
                                    name: t.name, cwd: t.cwd,
                                    agentKind: t.agentKind,
                                    sessionId: t.sessionId,
                                    transcriptPath: transcript,
                                    newTokens: t.newTokens, lastPrompt: t.lastPrompt,
                                    removedAt: Date())
        terminalArchive.removeAll { $0.id == t.id }
        terminalArchive.insert(entry, at: 0)          // newest first, which is how it is read
        // Trimmed per project, so a busy project cannot push a quiet one's history out.
        var kept: [UUID: Int] = [:]
        terminalArchive = terminalArchive.filter { row in
            let n = (kept[row.projectId] ?? 0) + 1
            kept[row.projectId] = n
            return n <= Self.archiveCap
        }
    }

    /// The rows the drawer lists — which is also what the button should count. A row with no
    /// transcript cannot be reopened and is never shown, so counting it made the badge disagree
    /// with the list it opens.
    func archived(inProject id: UUID) -> [TerminalArchive] {
        let path = project(id)?.path
        let mine = terminalArchive.filter { row in
            guard row.transcriptPath != nil else { return false }
            // Path first, id only for rows written before the path was recorded.
            if let rowPath = row.projectPath, !rowPath.isEmpty, let path { return rowPath == path }
            return row.projectId == id
        }
        // One row per conversation, newest first. Restoring a row from the drawer resumes the same
        // session, so removing that card archives a second row pointing at the same transcript —
        // two entries, one conversation. Counting both made the badge promise more than the list
        // shows, since the list collapses them.
        var seen = Set<String>()
        return mine.sorted { $0.removedAt > $1.removedAt }
            .filter { seen.insert($0.transcriptPath ?? "").inserted }
    }

    /// The node a dragged archive row resolves to: the last message of its transcript, which is
    /// what "resume this conversation" means when you are holding a file rather than a search hit.
    ///
    /// Cached because a drag's `onChanged` fires every frame, and a SQLite round trip per frame is
    /// the difference between a drag and a stutter. Misses are cached too — a transcript the index
    /// has never seen will not appear on the next frame either.
    private var archivedHits: [String: SearchIndex.Hit?] = [:]

    func archivedHit(for path: String) -> SearchIndex.Hit? {
        if let cached = archivedHits[path] { return cached }
        let hit = SearchIndex.lastHit(path: path)
        archivedHits[path] = hit
        return hit
    }

    func forgetArchived(_ id: UUID) {
        terminalArchive.removeAll { $0.id == id }
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

    /// The terminals a list should actually show, given the "only marked" filter. Applied at the
    /// display edges rather than inside the accessors below, so nothing that reasons about the
    /// fleet — status counts, the web snapshot, drag targets — can be silently narrowed by a
    /// setting about what is on screen.
    func visible(_ list: [TerminalSession]) -> [TerminalSession] {
        showOnlyMarked ? list.filter(\.subtaskDone) : list
    }

    /// How many terminals the filter is currently hiding (0 when it is off).
    var hiddenByMarkFilter: Int {
        showOnlyMarked ? terminals.filter { !$0.subtaskDone }.count : 0
    }

    /// The projects the board should draw. Under the filter a project with nothing marked is left
    /// out entirely rather than drawn as an empty frame: the point of the filter is a board with
    /// only the work you are tracking on it, and six empty headers is not that.
    var visibleProjects: [Project] {
        guard showOnlyMarked else { return projects }
        return projects.filter { !visible(terminals(inProject: $0.id)).isEmpty }
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

    /// The sidebar follows the board's filter: the two are the same list of work seen twice, and
    /// one of them quietly disagreeing about what exists is how you lose a terminal.
    var tasks: [TaskItem] {
        taskGroups.flatMap(\.tasks)
    }

    /// Tasks grouped by project (only projects that have at least one task).
    var taskGroups: [TaskGroup] {
        projects.compactMap { p in
            var items: [TaskItem] = []
            for c in clustersInProject(p.id) where !visible(members(ofCluster: c.id)).isEmpty {
                items.append(.cluster(c.id))
            }
            for t in visible(standaloneTerminals(inProject: p.id)) { items.append(.terminal(t.id)) }
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
    /// What a dragged card would land on, the way an icon dropped on a phone's home screen either
    /// makes a folder or falls into one.
    enum ClusterDrop: Equatable {
        case card(UUID)        // another loose card → the two become a cluster
        case cluster(UUID)     // anywhere inside a cluster box → join that task
        case leaveCluster      // empty board, dragged out of the cluster it was in → standalone
        case project(UUID)     // another project's section → the terminal moves there, history and all
    }
    /// The target under the cursor right now — nil when releasing here would do nothing.
    @Published var clusterDrop: ClusterDrop?
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
        // The dock's explicit zones win; the edge only claims what they don't; a card takes what is
        // left. In that order because the first two are overlays that appear *for* this drag and
        // light up under the cursor — a card that quietly outranked them would steal a drop aimed
        // at something the user can see they are aiming at.
        hoveredTreeZone = hoveredZone == nil && sessionTreeZoneFrame.contains(point)
        clusterDrop = (hoveredZone == nil && !hoveredTreeZone && !dockFrame.contains(point))
            ? clusterTarget(for: id, at: point) : nil
    }

    /// The dock's whole footprint, not just its zones. It is a floating panel with padding around
    /// and between them, so `hoveredZone == nil` is also true in the gaps — and a card lying under
    /// the dock would become the drop target through one of them, lit up underneath a panel that
    /// covers it.
    private var dockFrame: CGRect {
        let union = zoneFrames.values.reduce(CGRect.null) { $0.union($1) }
        return union.isNull ? .null : union.insetBy(dx: -14, dy: -14)
    }

    /// What the drop indicator should draw: the box being landed in, or — when the card is on its
    /// way out — the cluster it is leaving. `leaving` is what tells the two apart visually; they
    /// are opposite outcomes and must not look alike.
    struct DropIndicator {
        var rect: CGRect
        var radius: CGFloat
        var leaving: Bool = false
    }

    /// Where to draw it. Corner radii match what they are ringing, and a card is looked up by the
    /// copy the cursor is actually inside — a running terminal is on the board twice (RUNNING NOW
    /// and its project section).
    var clusterDropFrame: DropIndicator? {
        switch clusterDrop {
        case .cluster(let id):
            guard let r = clusterFrames[id]?.first(where: { $0.contains(dragLocation) }) else { return nil }
            return DropIndicator(rect: r, radius: 14)   // ClusterContainer's own corner radius
        case .card(let id):
            guard let r = cardFrames[id]?.first(where: { $0.contains(dragLocation) }) else { return nil }
            return DropIndicator(rect: r, radius: 12)   // TerminalCardView's
        case .project(let id):
            // Falls back to the section's frame when the cursor is not inside it — dropping onto a
            // foreign card in the RUNNING NOW strip lands in that card's project, and the ring
            // showing where it is going is worth more there than one drawn around the cursor.
            guard let r = projectFrames[id]?.first(where: { $0.contains(dragLocation) })
                       ?? projectFrames[id]?.first else { return nil }
            return DropIndicator(rect: r, radius: 14)
        case .leaveCluster:
            // Ring the cluster being left, not the empty space being dropped into: the point of the
            // gesture is which task this card is walking out of. Absent when that box is scrolled
            // out of view, where the cursor chip is the only thing that can still speak.
            guard let id = draggingTerminalId,
                  let c = terminals.first(where: { $0.id == id })?.clusterId,
                  let r = clusterFrames[c]?.first else { return nil }
            return DropIndicator(rect: r, radius: 14, leaving: true)
        case nil:
            return nil
        }
    }

    /// The card being dragged, where it still sits. The real card never moves — a chip follows the
    /// cursor instead — so without marking it the board gives no sign of *which* one was picked up.
    /// Both copies, when it is a running terminal drawn twice.
    var dragSourceCardFrames: [CGRect] {
        guard let id = draggingTerminalId else { return [] }
        return cardFrames[id] ?? []
    }

    /// The cluster the dragged card is currently in — the task it would be leaving.
    ///
    /// Withheld once the drop would actually leave it: the "leaving" indicator rings the same box,
    /// and two outlines on one rectangle is not two pieces of information.
    var dragSourceClusterFrame: CGRect? {
        guard let id = draggingTerminalId, clusterDrop != .leaveCluster,
              let c = terminals.first(where: { $0.id == id })?.clusterId,
              let r = clusterFrames[c]?.first else { return nil }
        return r
    }

    /// What is under the cursor that this card could join.
    ///
    /// A cluster box wins over the member cards inside it: the task is what you are aiming at, and
    /// which member card happens to sit under the cursor changes nothing about where the drop lands.
    /// It also means the gaps between member cards, the cluster header and its padding all work,
    /// instead of being dead space inside a target that looks like one box.
    ///
    /// Same project only, in both cases: `members(ofCluster:)` collects by cluster id alone while
    /// `clustersInProject` places a cluster by its members, so a cluster spanning two projects
    /// renders in full under both of their headers — the same cards, twice.
    private func clusterTarget(for id: UUID, at point: CGPoint) -> ClusterDrop? {
        guard let src = terminals.first(where: { $0.id == id }) else { return nil }

        // Inside a cluster box: join that task — or, if it is the one this card is already in,
        // nothing at all. Returning here rather than falling through matters: every member card is
        // inside the box, so the card branch below would otherwise re-answer the same question.
        if let hit = clusterFrames.first(where: { $0.value.contains { $0.contains(point) } })?.key {
            if hit == src.clusterId { return nil }
            guard let owner = members(ofCluster: hit).first?.projectId else { return nil }
            // Another project's cluster is not a group this card can join — a cluster lives inside
            // one project — so what it names is that project.
            return owner == src.projectId ? .cluster(hit) : .project(owner)
        }

        if let hit = cardFrames.first(where: { entry in
               entry.key != id && entry.value.contains { $0.contains(point) }
           })?.key,
           let target = terminals.first(where: { $0.id == hit }) {
            return target.projectId == src.projectId ? .card(hit) : .project(target.projectId)
        }

        // Anywhere in another project's section. Below the two branches above so a drop inside your
        // own project still means exactly what it always did, and above the board branch so the
        // whole area of a section works rather than only the gaps between its cards.
        if let hit = projectFrames.first(where: { $0.value.contains { $0.contains(point) } })?.key,
           hit != src.projectId {
            return .project(hit)
        }

        // Empty board. For a card that belongs to a cluster this is the other half of the phone
        // gesture: dragged out of the folder and left standing on its own. For one that doesn't,
        // there is nothing here to do — which is what releasing on the board has always meant.
        if src.clusterId != nil, boardFrame.contains(point) { return .leaveCluster }
        return nil
    }

    /// Carry out what the drag was aiming at: join a task, form one, or walk out of the one it was
    /// in. Dropped on a cluster it joins that one; dropped on a loose card, `ensureCluster` makes a
    /// fresh cluster named after that card and both end up in it.
    func applyClusterDrop(_ dragged: UUID, _ drop: ClusterDrop) {
        // The same operation the dock's Leave Cluster zone performs, reached by the other gesture.
        if drop == .leaveCluster { removeFromCluster(dragged); return }
        if case .project(let p) = drop { moveTerminal(dragged, toProject: p); return }
        audited(AuditIntent("terminal.group",
                            categories: ["configuration"],
                            target: auditTarget(terminal: dragged),
                            message: "grouped into a cluster")) {
            let cluster: UUID?
            switch drop {
            case .cluster(let c): cluster = c
            case .card(let t):    cluster = ensureCluster(for: t)
            case .leaveCluster,
                 .project:        cluster = nil     // both returned above
            }
            guard let cluster,
                  let i = terminals.firstIndex(where: { $0.id == dragged }),
                  terminals[i].clusterId != cluster else { return }
            terminals[i].clusterId = cluster
            pruneClusters()          // the card it left behind may have emptied its old cluster
            save()
        }
    }

    func dragEnded(at point: CGPoint) {
        let zone = zoneAt(point)
        let onTreeZone = hoveredTreeZone
        // What was highlighted, not what a fresh hit-test says: the drop belongs to the thing the
        // user could see was lit.
        let drop = clusterDrop
        let id = draggingTerminalId
        draggingTerminalId = nil
        hoveredZone = nil
        hoveredTreeZone = false
        clusterDrop = nil
        guard let id else { return }
        if let zone { perform(zone, on: id) }
        else if onTreeZone { openSessionTree(id) }
        else if let drop { applyClusterDrop(id, drop) }
    }

    func cancelDrag() {
        draggingTerminalId = nil
        hoveredZone = nil
        hoveredTreeZone = false
        clusterDrop = nil
    }

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
        enterStatus(s, at: idx)
    }

    /// The one place a terminal's status changes, so the run clock cannot drift from it.
    ///
    /// The clock belongs to the *turn*, not to the status. It starts when work starts, survives a
    /// permission prompt in the middle of that work — approving must not restart the count at zero —
    /// and only stops when the turn does. The transition is what matters, not the assignment:
    /// `PreToolUse`/`PostToolUse` restate `working` many times per turn, and restarting on each
    /// would report the age of the last tool call instead of the run.
    func enterStatus(_ s: TermStatus, at idx: Int) {
        switch s {
        case .working:
            if terminals[idx].runningSince == nil { terminals[idx].runningSince = Date() }
        case .needsYou:
            break                                   // same turn, waiting on you — keep counting
        case .idle, .shell, .closed, .exited:
            finishRun(at: idx, endedBy: s.label)
        }
        terminals[idx].status = s
    }

    /// A run ended: freeze its length on the card and write it down.
    ///
    /// Logged here rather than derived later because this is the only moment it is known — the
    /// transcript records what the agent did, never how long it took, and the start time is about
    /// to be cleared. `endedBy` says what stopped it (returned, needs-you never appears here, the
    /// window closed, a new prompt arrived), which is the difference between a turn that finished
    /// and one that was cut off.
    func finishRun(at idx: Int, endedBy: String) {
        guard let since = terminals[idx].runningSince else { return }
        let seconds = max(0, Int(Date().timeIntervalSince(since)))
        terminals[idx].runningSince = nil
        terminals[idx].lastRunSeconds = seconds
        let t = terminals[idx]
        FV.log("run finished: term=\(t.name) after=\(RelativeTime.clock(seconds: seconds)) " +
               "(\(seconds)s) ended=\(endedBy)")
        audit.emit("fleetview.terminal.run_finished",
                   categories: ["process"],
                   message: "\(t.name) ran for \(RelativeTime.clock(seconds: seconds))",
                   target: auditTarget(terminal: t.id),
                   data: ["run.seconds": .int(seconds), "run.ended_by": .string(endedBy)],
                   durationNanos: seconds * 1_000_000_000)
    }

    /// The user pressed Escape (Claude's interrupt) — if the agent was working, the turn just ended,
    /// so clear the stuck "working" immediately (no Stop hook fires on an interrupt).
    func handleInterrupt(_ id: UUID) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[idx].lastActivity = Date()   // pressing Esc is a real interaction
        guard terminals[idx].status == .working else { return }
        enterStatus(.idle, at: idx)
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
        // A hook fired → real agent/shell activity in this terminal. Written at a 5s granularity,
        // because `terminals` is @Published and a fresh Date is never value-equal: writing it on
        // every event re-rendered the WHOLE board, and PreToolUse/PostToolUse arrive in bursts many
        // times a second (they are ~95% of the event log). Nothing displays it more finely than
        // that — it is rendered through RelativeTime.short inside a 15s TimelineView.
        let now = Date()
        if terminals[idx].lastActivity.map({ now.timeIntervalSince($0) >= 5 }) ?? true {
            terminals[idx].lastActivity = now
        }
        if let sid = ev.sessionId { terminals[idx].sessionId = sid }
        if let tp = ev.transcriptPath {
            terminals[idx].transcriptPath = tp
            // Tell Claude vs Codex apart by where the transcript lives (drives the card's colour cue).
            if tp.contains("/.codex/") { terminals[idx].agentKind = .codex }
            else if tp.contains("/.claude/") { terminals[idx].agentKind = .claude }
        }

        switch ev.event {
        case "UserPromptSubmit":
            // A new prompt is a new run even if the card never left `working` (a queued follow-up),
            // so close the old one out — otherwise its length would be overwritten unrecorded — and
            // start the clock again rather than going through `enterStatus`'s transition.
            finishRun(at: idx, endedBy: "new prompt")
            terminals[idx].runningSince = Date()
            terminals[idx].status = .working
            if let p = ev.prompt {
                let oneLine = p.replacingOccurrences(of: "\n", with: " ")
                              .trimmingCharacters(in: .whitespacesAndNewlines)
                if !oneLine.isEmpty { terminals[idx].lastPrompt = oneLine }
            }
        case "PreToolUse", "PostToolUse":
            // A tool is starting/finishing → the agent is actively working. Crucially this clears a
            // prior "needs you" the moment the user approves a permission prompt (Claude & Codex).
            if terminals[idx].status != .working { enterStatus(.working, at: idx) }
        case "PermissionRequest":
            // Codex fires this before an approval prompt (Claude uses "Notification", handled below).
            enterStatus(.needsYou, at: idx)
        case "Stop":
            enterStatus(.idle, at: idx)
        case "Notification":
            // The Notification hook fires for BOTH permission requests and idle "waiting for input".
            // Only a permission/approval request is a genuine "needs you"; idle just means returned.
            let msg = (ev.message ?? "").lowercased()
            if msg.contains("permission") || msg.contains("approve") || msg.contains("approval") || msg.contains("confirm") {
                enterStatus(.needsYou, at: idx)
            } else if msg.contains("waiting") || msg.contains("finished") || msg.contains("idle") {
                enterStatus(.idle, at: idx)   // explicit idle signal clears a stuck "working" (e.g. after an interrupt)
            } else if terminals[idx].status != .working {
                enterStatus(.idle, at: idx)
            }
        case "SessionStart":
            // A Claude session is now active → leave "shell", show as an agent terminal.
            if terminals[idx].status != .working && terminals[idx].status != .needsYou {
                enterStatus(.idle, at: idx)
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
            enterStatus(.shell, at: idx)
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
            // Manage the shared Notes list from the web (it drives the quick-command chips) and,
            // through the same route, from another FleetView mirroring this list in its sidebar.
            // `upd` exists so an edit stays an edit: delete-then-add would give the note a new id
            // and move it to the end of everyone's list for a change of one character.
            if let add = query["add"] { addNote(add) }
            else if let u = query["upd"], let nid = UUID(uuidString: u) {
                updateNote(nid, text: query["text"] ?? "")
            }
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
        // Codex is resolved from its rollouts FIRST, ahead of the hook pointer, because that pointer
        // goes stale and stays stale: Codex silently skips hooks it has not been told to trust (see
        // CodexSession), and once they stop firing the pointer is frozen at whatever rollout was
        // current at the time while Codex goes on to open new ones. One terminal here was pinned to
        // a rollout from two days earlier and the web chat showed that conversation instead of the
        // live one. The rollouts cannot go stale — asking them is what makes a running session
        // correct — and when hooks ARE working both answers are the same file anyway.
        if t.agentKind == .codex {
            let claimed = Set(terminals.filter { $0.id != id }.compactMap { $0.transcriptPath })
            if let live = CodexSession.currentRollout(cwd: t.cwd, excluding: claimed) { return live }
        }
        // The pointer hook.sh writes for this terminal wins for Claude: it is rewritten on every
        // hook event, so it survives a missed event or a `--resume` that switched sessions.
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
                             // Elapsed seconds, not a timestamp: the phone's clock is its own, and a
                             // start time sent across would be read against it.
                             running: t.status == .working
                                 ? (t.runningSince.map { max(0, Int(Date().timeIntervalSince($0))) } ?? -1)
                                 : -1,
                             lastRun: t.lastRunSeconds ?? -1,
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
            remoteHint: remote.unavailableReason,
            askGeo: AuditConfig.current.wantsBrowserLocation,
            dark: Theme.isDark)
    }

    /// Start (or reuse) a web terminal for an open session and return its URL (nil if not attachable).
    private func webOpenTerminal(_ id: UUID) -> RemoteServer.Endpoint? {
        guard remote.available, let t = terminals.first(where: { $0.id == id }) else { return nil }
        guard remote.sessionExists(id) else { return nil }
        return remote.endpoint(for: id, name: t.name)
    }

    // MARK: - Window plumbing

    /// `autoRun` overrides the terminal's own setting — a reopen that is about to type a `--resume`
    /// command has to make sure nothing else is typed first.
    private func openWindow(for t: TerminalSession, autoRun: Bool? = nil) {
        // Run under tmux when remote access is available (so the web view can attach to the same
        // session). Only auto-type `claude` when we're *creating* the session — re-attaching to a
        // persisted one (reopen after the window was closed) would spawn a second claude.
        let spec = remote.tmuxSpec(for: t.id)
        let autoRun = autoRun ?? (t.autoRunClaude && !(spec != nil && remote.sessionExists(t.id)))
        let ctrl = TerminalWindowController(termId: t.id, title: t.name, cwd: t.cwd,
                                            autoRunClaude: autoRun, port: hookPort, tmux: spec,
                                            fontSize: terminalFontSize)
        ctrl.onExit = { [weak self] id, _ in
            Task { @MainActor in self?.setStatus(id, .exited) }
        }
        ctrl.onClose = { [weak self] id in
            Task { @MainActor in self?.handleWindowClosed(id) }
        }
        ctrl.onInterrupt = { [weak self] id in
            Task { @MainActor in self?.handleInterrupt(id) }
        }
        ctrl.onZoomed = { [weak self] size in
            Task { @MainActor in self?.setTerminalFontSize(size) }
        }
        controllers[t.id] = ctrl
        ctrl.show(cascadeFrom: &cascadePoint)
    }

    /// Adopt a terminal font size for the whole fleet: every open window, and every one opened from
    /// here on. Called by the ⌘+/⌘− menu items and by a pinch once the fingers lift.
    func setTerminalFontSize(_ size: Double) {
        let clamped = min(TerminalWindowController.fontSizeRange.upperBound,
                          max(TerminalWindowController.fontSizeRange.lowerBound, size.rounded()))
        // Not guarded on `clamped != terminalFontSize`: the window that was pinched is already at
        // this size while the others are not, so the setting agreeing does not mean the fleet does.
        terminalFontSize = clamped
        for c in controllers.values { c.setFontSize(clamped) }
        save()
    }

    /// A terminal window closed — so close the terminal.
    ///
    /// The session used to survive, on the theory that a window is only one view of it. But nothing
    /// on the board said so: the card read "closed" while the agent behind it kept working and
    /// spending tokens, and the only way to find out was `tmux ls`. Sessions that are *meant* to
    /// outlive their window still do — quitting FleetView leaves them alone unless
    /// `closeTerminalsOnQuit` says otherwise, and the next launch reattaches them.
    ///
    /// The kill is skipped when the controller has already been dropped, which is how the bulk
    /// paths opt out: `closeAllTerminals` clears them first and uses one `kill-server`, and
    /// `removeTerminal` has already stopped this one.
    private func handleWindowClosed(_ id: UUID) {
        let wasTracked = controllers.removeValue(forKey: id) != nil
        if wasTracked && !isQuitting { remote.stop(id) }
        if let idx = terminals.firstIndex(where: { $0.id == id }), terminals[idx].status != .exited {
            enterStatus(.closed, at: idx)
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
