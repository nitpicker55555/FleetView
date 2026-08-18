import Foundation
import SwiftUI

/// Drives the search panel: debounced querying, grouping, and the index's own progress.
///
/// Hits arrive ranked but flat, and flat is unreadable here — `看看进度` alone appears 292 times
/// across 52 sessions. So results are grouped by transcript, which is also the unit you actually
/// want: "which conversation was that in".
@MainActor
final class SearchModel: ObservableObject {

    /// Searching widens in three steps, and the default is the narrowest thing that is usually
    /// what you meant. Tab moves outward.
    ///
    /// - `fleet` — what is on the board right now: projects, clusters, terminals, by name, path or
    ///   id. This is navigation, not recall, and it is most of what a search box gets used for.
    /// - `session` — inside the conversation you have open.
    /// - `history` — every conversation ever recorded, live or not.
    enum Mode: Int, CaseIterable, Identifiable {
        case fleet, session, history
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .fleet:   return "Fleet"
            case .session: return "当前会话"
            case .history: return "全部历史"
            }
        }
        var next: Mode { Mode(rawValue: rawValue + 1) ?? .fleet }
    }

    /// One thing on the board that matched. Terminals carry the live detail; a project or cluster
    /// row is the header you can also act on.
    struct FleetHit: Identifiable {
        enum Kind { case project, cluster, terminal }
        let id: UUID
        let kind: Kind
        let name: String
        let detail: String              // path, member count, or the terminal's last prompt
        let projectId: UUID?
        let clusterName: String?
        let status: TermStatus?
        let agent: AgentKind?
        let why: String                 // which field matched — shown so a uuid hit isn't baffling
    }

    /// Hits from one transcript, newest-ranked first.
    struct Group: Identifiable {
        let id: String                  // transcript path — one file is one session
        let src: SearchIndex.Source
        let project: String
        let session: String
        let when: String
        var hits: [SearchIndex.Hit]
    }

    /// The level above a session. Answers "how many projects matched, and which one do I want" —
    /// without it a global search is a flat wall with no way to aim.
    struct ProjectGroup: Identifiable {
        let id: String                  // project path ("" when the transcript never recorded one)
        let name: String
        var sessions: [Group]
        var fleet: [FleetHit]           // fleet mode: the terminals/clusters under this project
        var count: Int                  // hits below, across everything
    }

    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var scope: SearchIndex.Scope = .both { didSet { runSearch() } }
    @Published var source: SearchIndex.Source? { didSet { runSearch() } }
    @Published var mode: Mode = .fleet { didSet { runSearch() } }

    /// Set once when the panel opens — fleet mode reads the live board through it.
    weak var app: AppState?

    /// Which project is expanded. nil = all collapsed to headers; a path = that one open.
    @Published var focusedProject: String?

    @Published private(set) var projectGroups: [ProjectGroup] = []
    @Published private(set) var groups: [Group] = []
    @Published private(set) var total = 0
    @Published private(set) var elapsed: Double = 0     // ms
    @Published private(set) var truncated = false

    @Published private(set) var indexing = false
    @Published private(set) var indexNote = ""
    @Published private(set) var stats: (messages: Int, files: Int) = (0, 0)

    /// The hit currently being opened — resolving a fork can take a moment, and a click with no
    /// feedback reads as a dead button.
    @Published var opening: Int64?
    @Published var failure: String?

    private var pending: DispatchWorkItem?
    private let limit = 300

    // MARK: - Index

    /// Refresh the index, then re-run whatever is in the box. Cheap when nothing changed (~40 ms).
    func refreshIndex() {
        guard !indexing else { return }
        indexing = true
        indexNote = stats.messages == 0 ? "建立索引…" : "更新索引…"
        SearchIndex.refresh(progress: { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                self.indexNote = "索引 \(p.files)/\(p.total) · \(p.messages) 条"
            }
        }, done: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.indexing = false
                self.indexNote = ""
                self.stats = SearchIndex.stats()
                self.runSearch()
            }
        })
    }

    // MARK: - Query

    private func scheduleSearch() {
        pending?.cancel()
        // Queries land in single-digit milliseconds, so this is only to keep a fast typist from
        // re-rendering the list on every keystroke.
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            groups = []; projectGroups = []; total = 0; elapsed = 0; truncated = false
            return
        }
        if mode == .fleet { runFleetSearch(q); return }

        // `session` is the same index as `history`, narrowed to the open conversation — one code
        // path, so ranking and CJK handling cannot drift between the two.
        let paths = mode == .session ? openTranscripts() : []
        if mode == .session, paths.isEmpty {
            groups = []; projectGroups = []; total = 0; truncated = false
            failure = "没有打开的会话"
            return
        }
        failure = nil
        let scope = self.scope, source = self.source, limit = self.limit
        let started = Date()
        // Off the main actor: SQLite is fast here, but the panel must not hitch while typing.
        Task.detached(priority: .userInitiated) {
            let hits = SearchIndex.search(q, scope: scope, limit: limit, source: source, paths: paths)
            let sessions = Self.group(hits)
            let ms = Date().timeIntervalSince(started) * 1000
            await MainActor.run { [weak self] in
                guard let self, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == q
                else { return }                      // a newer keystroke already won
                self.groups = sessions
                self.projectGroups = self.byProject(sessions)
                self.total = hits.count
                self.truncated = hits.count >= limit
                self.elapsed = ms
                self.autoFocusSingleProject()
            }
        }
    }

    /// The transcripts that count as "the conversation you have open": the terminal whose session
    /// tree is up, or failing that the one that moved most recently.
    private func openTranscripts() -> [String] {
        guard let app else { return [] }
        if let id = app.treePanelTerminalId, let p = app.transcriptPath(for: id) { return [p] }
        let recent = app.terminals
            .filter { $0.status != .closed }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        if let t = recent.first, let p = app.transcriptPath(for: t.id) { return [p] }
        return []
    }

    // MARK: - Fleet

    /// Match the board itself. Cheap enough to do inline on every keystroke — it is tens of rows,
    /// not a hundred thousand messages.
    private func runFleetSearch(_ q: String) {
        failure = nil
        let started = Date()
        guard let app else { projectGroups = []; total = 0; return }
        let needle = q.lowercased()

        /// A terminal's id is the one thing you copy from a card and paste here, so it matches on
        /// any prefix and ignores the dashes people drop when retyping it.
        func idMatches(_ id: UUID) -> Bool {
            let s = id.uuidString.lowercased()
            let bare = s.replacingOccurrences(of: "-", with: "")
            let want = needle.replacingOccurrences(of: "-", with: "")
            return want.count >= 2 && (s.hasPrefix(needle) || bare.hasPrefix(want))
        }

        var byProject: [UUID: [FleetHit]] = [:]
        var looseProjects: [FleetHit] = []

        for p in app.projects where p.name.lowercased().contains(needle)
            || p.path.lowercased().contains(needle) || idMatches(p.id) {
            looseProjects.append(FleetHit(id: p.id, kind: .project, name: p.name, detail: p.path,
                                          projectId: p.id, clusterName: nil, status: nil,
                                          agent: nil, why: "project"))
        }
        for c in app.clusters where c.name.lowercased().contains(needle) || idMatches(c.id) {
            let members = app.terminals.filter { $0.clusterId == c.id }
            byProject[members.first?.projectId ?? UUID(), default: []].append(
                FleetHit(id: c.id, kind: .cluster, name: c.name,
                         detail: "\(members.count) terminal\(members.count == 1 ? "" : "s")",
                         projectId: members.first?.projectId, clusterName: nil,
                         status: nil, agent: nil, why: "cluster"))
        }
        for t in app.terminals {
            var why: String?
            if t.name.lowercased().contains(needle) { why = "name" }
            else if idMatches(t.id) { why = "id" }
            else if t.cwd.lowercased().contains(needle) { why = "cwd" }
            // The last prompt is what a terminal is *doing*, which is often how you remember it.
            else if t.lastPrompt.lowercased().contains(needle) { why = "prompt" }
            guard let why else { continue }
            let cluster = app.clusters.first { $0.id == t.clusterId }?.name
            let detail = why == "prompt" ? t.lastPrompt.replacingOccurrences(of: "\n", with: " ")
                                         : t.cwd
            byProject[t.projectId, default: []].append(
                FleetHit(id: t.id, kind: .terminal, name: t.name, detail: detail,
                         projectId: t.projectId, clusterName: cluster,
                         status: t.status, agent: t.agentKind, why: why))
        }

        // One row per project, matched projects first, then whatever had matching children.
        var out: [ProjectGroup] = []
        var seen = Set<UUID>()
        func push(_ pid: UUID, _ own: [FleetHit]) {
            guard !seen.contains(pid) else { return }
            seen.insert(pid)
            let proj = app.projects.first { $0.id == pid }
            let kids = byProject[pid] ?? []
            guard !own.isEmpty || !kids.isEmpty else { return }
            out.append(ProjectGroup(id: proj?.path ?? pid.uuidString,
                                    name: proj?.name ?? "—",
                                    sessions: [], fleet: own + kids,
                                    count: own.count + kids.count))
        }
        for hit in looseProjects { push(hit.projectId ?? hit.id, [hit]) }
        for pid in byProject.keys { push(pid, []) }

        projectGroups = out
        groups = []
        total = out.reduce(0) { $0 + $1.count }
        truncated = false
        elapsed = Date().timeIntervalSince(started) * 1000
        autoFocusSingleProject()
    }

    /// With one project matched there is nothing to choose between, so open it rather than making
    /// the reader click a header to see the only answer.
    private func autoFocusSingleProject() {
        if projectGroups.count == 1 { focusedProject = projectGroups[0].id }
        else if let f = focusedProject, !projectGroups.contains(where: { $0.id == f }) {
            focusedProject = nil
        }
    }

    /// Bucket by transcript, preserving BM25 order: the first time a file appears decides where
    /// its group sits, so the best match still floats to the top.
    nonisolated private static func group(_ hits: [SearchIndex.Hit]) -> [Group] {
        var order: [String] = []
        var byPath: [String: Group] = [:]
        for h in hits {
            if var g = byPath[h.path] {
                g.hits.append(h)
                byPath[h.path] = g
            } else {
                order.append(h.path)
                byPath[h.path] = Group(id: h.path, src: h.src,
                                       project: h.project.isEmpty ? "—" : h.project,
                                       session: h.session, when: h.ts, hits: [h])
            }
        }
        return order.compactMap { byPath[$0] }
    }

    /// Sessions rolled up under the project they ran in, in the order the best hit appeared.
    private func byProject(_ sessions: [Group]) -> [ProjectGroup] {
        var order: [String] = []
        var acc: [String: ProjectGroup] = [:]
        for s in sessions {
            let key = s.project
            if var g = acc[key] {
                g.sessions.append(s)
                g.count += s.hits.count
                acc[key] = g
            } else {
                order.append(key)
                acc[key] = ProjectGroup(id: key,
                                        name: key == "—" ? "未知项目" : (key as NSString).lastPathComponent,
                                        sessions: [s], fleet: [], count: s.hits.count)
            }
        }
        return order.compactMap { acc[$0] }
    }

    // MARK: - Preview

    /// A hit with the conversation around it. Reading costs nothing; only opening writes.
    struct Preview: Identifiable {
        let id: Int64
        let hit: SearchIndex.Hit
        let context: [SearchIndex.Hit]
    }

    @Published var preview: Preview?

    /// Clicking a result reads it — it does NOT resume it. Measured on this corpus, only 3% of
    /// nodes are natively resumable, so opening every result you glance at would write a ~10 MB
    /// fork each time. Reading comes from the index, so browsing stays free and forking becomes a
    /// deliberate second step.
    /// Paints the window first, then replaces it with the whole conversation.
    ///
    /// Two steps rather than one because they cost differently: the window is two indexed lookups
    /// and is on screen immediately, while a long rollout is thousands of rows. Waiting for the
    /// second before showing anything would make every result feel slow; showing only the first is
    /// what made a hit a fragment. The guard on `preview?.id` is what stops a slow load from
    /// landing on a result you have already clicked past.
    func showPreview(_ hit: SearchIndex.Hit) {
        let current = preview
        Task.detached(priority: .userInitiated) {
            let context = SearchIndex.context(around: hit)
            await MainActor.run { [weak self] in
                guard let self, current?.id == self.preview?.id else { return }
                self.preview = Preview(id: hit.id, hit: hit, context: context)
            }
            let whole = SearchIndex.conversation(of: hit)
            guard whole.count > context.count else { return }   // already the whole thing
            await MainActor.run { [weak self] in
                guard let self, self.preview?.id == hit.id else { return }
                self.preview = Preview(id: hit.id, hit: hit, context: whole)
            }
        }
    }

    func closePreview() { preview = nil }

    // MARK: - Open

    /// Resolve a hit into a resumed terminal. Runs the fork off the main actor — synthesising a
    /// long chain takes hundreds of milliseconds, and for a big Codex rollout several seconds.
    func open(_ hit: SearchIndex.Hit, in state: AppState, joinClusterOf card: UUID? = nil) {
        guard opening == nil else { return }
        opening = hit.id
        failure = nil
        Task.detached(priority: .userInitiated) {
            do {
                let plan = try SearchOpen.plan(for: hit)
                await MainActor.run {
                    self.preview = nil
                    state.openSearchPlan(plan, joinClusterOf: card)
                    self.opening = nil
                }
            } catch {
                await MainActor.run {
                    self.failure = error.localizedDescription
                    self.opening = nil
                    FV.log("search open failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
