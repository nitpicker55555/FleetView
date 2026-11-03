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
        case fleet, session, history, archive
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .fleet:   return L(.modeFleet)
            case .session: return L(.modeSession)
            case .history: return L(.modeHistory)
            case .archive: return L(.modeArchive)
            }
        }
        var icon: String {
            switch self {
            case .fleet:   return "rectangle.on.rectangle"
            case .session: return "bubble.left"
            case .history: return "clock"
            case .archive: return "archivebox"
            }
        }
        var next: Mode { Mode(rawValue: rawValue + 1) ?? .fleet }
        var previous: Mode { Mode(rawValue: rawValue - 1) ?? .archive }
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
        /// The removed card this transcript last lived in — archive mode only. There every row is
        /// the same project, and what tells them apart is the card: its name and its last prompt.
        var card: TerminalArchive? = nil
        /// The card this conversation ran in, on the board or long gone (see
        /// `AppState.cardsByTranscript`). nil when no card ever held it — a `claude` started in a
        /// plain terminal.
        var holder: CommitAuthor? = nil
        /// Listed because its card's *name* matched, not anything said in it: `hits` is then only
        /// the conversation's last message, standing in for the whole of it.
        var byCardName = false
        /// The same, for its project's name (see `namedProjectConversations`).
        var byProjectName = false
    }

    /// The level between a project and its messages: one card's share of them. Only drawn where it
    /// tells something apart (see `ProjectGroup.cards`).
    struct CardGroup: Identifiable {
        let id: String                  // "<project path>|<card id>", "|" alone for no card
        let holder: CommitAuthor?
        var sessions: [Group]
        var count: Int
        var newest: String
    }

    /// The level above a session. Answers "how many projects matched, and which one do I want" —
    /// without it a global search is a flat wall with no way to aim.
    struct ProjectGroup: Identifiable {
        let id: String                  // project path ("" when the transcript never recorded one)
        let name: String
        var sessions: [Group]
        var fleet: [FleetHit]           // fleet mode: the terminals/clusters under this project
        var count: Int                  // hits below, across everything
        /// The newest matching message, which is what projects and their hits are ordered by.
        var newest: String = ""
        /// Its conversations by the card that held them, newest first — only when the hits come
        /// from more than one card and some card has several. Then a flat list is the same card's
        /// messages strewn between the others', and which card it was is what you aim at next.
        /// Empty otherwise, and the project's hits are listed flat, each naming its card.
        var cards: [CardGroup] = []
        /// Its name matched: its whole history is listed, and always by card — the cards are what
        /// was asked for.
        var byName = false
    }

    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var scope: SearchIndex.Scope = .both { didSet { runSearch() } }
    @Published var source: SearchIndex.Source? { didSet { runSearch() } }
    @Published var mode: Mode = .fleet { didSet { runSearch() } }

    /// Set once when the panel opens — fleet mode reads the live board through it.
    weak var app: AppState?

    /// The projects opened in the list. Conversation results arrive as a list of projects, all
    /// closed: which project is the first thing you aim at, and a list of hundreds of messages
    /// with the project in grey under each one gave nothing to aim with.
    @Published var expandedProjects: Set<String> = []

    /// Board and archive results are short and are the answer themselves; they are never folded.
    var folds: Bool { mode == .history || mode == .session }

    func isExpanded(_ p: ProjectGroup) -> Bool { !folds || expandedProjects.contains(p.id) }

    func toggle(_ p: ProjectGroup) {
        if expandedProjects.contains(p.id) { expandedProjects.remove(p.id) }
        else { expandedProjects.insert(p.id) }
    }

    /// The cards opened in the list. Closed to begin with, like projects: the card is the choice.
    @Published var expandedCards: Set<String> = []

    func isExpanded(_ c: CardGroup) -> Bool { expandedCards.contains(c.id) }

    func toggle(_ c: CardGroup) {
        if expandedCards.contains(c.id) { expandedCards.remove(c.id) }
        else { expandedCards.insert(c.id) }
    }

    /// Each listed message as the list draws it, windowed onto its first match — worked out with the
    /// results rather than in the row. A pasted log runs to 250 KB, and flattening one to show 240
    /// characters on every redraw of every visible row is part of what made browsing stall.
    private(set) var snippets: [Int64: String] = [:]

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
    /// What `opening` is doing: resuming at the latest rather than at a step. Only the button that
    /// was pressed shows the spinner.
    @Published var openingLatest = false
    @Published var failure: String?

    private var pending: DispatchWorkItem?
    private let limit = 300
    /// Which card held each conversation, taken once per opening of the panel: it reads every card's
    /// hook pointer from disk, which is not something to do again on every keystroke, and the cards
    /// do not change while you search.
    private var book: AppState.CardBook?

    // MARK: - Index

    /// Refresh the index, then re-run whatever is in the box. Cheap when nothing changed (~40 ms).
    func refreshIndex() {
        guard !indexing else { return }
        indexing = true
        indexNote = stats.messages == 0 ? L(.indexBuilding) : L(.indexUpdating)
        SearchIndex.refresh(progress: { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                self.indexNote = L(.indexProgress(p.files, p.total, p.messages))
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

    /// In archive mode, which project's removed terminals are listed. nil = every project.
    @Published var archiveProject: UUID? { didSet { runSearch() } }

    func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Archive mode lists rather than searches, so an empty box is a full list, not no result.
        if mode == .archive { runArchiveSearch(q); return }
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
            failure = L(.searchNoSession)
            return
        }
        failure = nil
        let scope = self.scope, source = self.source, limit = self.limit
        if book == nil { book = app?.cardBook() }
        let book = self.book
        // Inside one conversation every hit is the same card, so its name picks out nothing.
        let byName = mode == .history
        let board = (app?.projects ?? []).map { (path: $0.path, name: $0.name) }
        let started = Date()
        // Off the main actor: SQLite is fast here, but the panel must not hitch while typing.
        Task.detached(priority: .userInitiated) {
            let hits = SearchIndex.search(q, scope: scope, limit: limit, source: source, paths: paths)
            let cards = book.map { AppState.cardsByTranscript($0) } ?? [:]
            let named = byName ? Self.namedConversations(q, cards: cards, besides: Set(hits.map(\.path)),
                                                         source: source) : []
            let inProjects = byName ? Self.namedProjectConversations(q, board: board,
                                                                     besides: Set((hits + named).map(\.path)),
                                                                     source: source) : []
            let byId = Dictionary(cards.map { (Self.conversationId($0.key), $0.value) },
                                  uniquingKeysWith: { a, _ in a })
            let sessions = (Self.group(hits)
                            + Self.group(named).map { g -> Group in
                                var g = g
                                g.byCardName = true
                                return g
                            }
                            + Self.group(inProjects).map { g -> Group in
                                var g = g
                                g.byProjectName = true
                                return g
                            })
                .map { g -> Group in
                    var g = g
                    g.holder = Self.holder(of: g.id, in: cards, byId: byId)
                    return g
                }
            let terms = SearchIndex.terms(q)
            let snippets = Dictionary((hits + named + inProjects).map { ($0.id, Self.snippet($0.body, terms: terms)) },
                                      uniquingKeysWith: { a, _ in a })
            let ms = Date().timeIntervalSince(started) * 1000
            await MainActor.run { [weak self] in
                guard let self, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == q
                else { return }                      // a newer keystroke already won
                self.snippets = snippets
                self.groups = sessions
                self.projectGroups = self.byProject(sessions)
                self.total = hits.count + named.count + inProjects.count
                self.truncated = hits.count >= limit
                self.elapsed = ms
                self.autoFocusSingleProject()
            }
        }
    }

    /// The conversations of every card whose name has all of the query's terms in it, as their last
    /// messages — less the ones already found by what was said in them. Card names are unique on the
    /// board now, so a name is a way to ask for one card's history; the board itself (`fleet`) only
    /// knows the cards still on it, and only the conversation each is in now.
    nonisolated private static func namedConversations(_ q: String, cards: [String: CommitAuthor],
                                                       besides found: Set<String>,
                                                       source: SearchIndex.Source?) -> [SearchIndex.Hit] {
        let terms = SearchIndex.terms(q).map { $0.lowercased() }
        // One letter is in most names, and would list the whole history as "matched by name".
        guard terms.joined().count >= 2 else { return [] }
        let paths = cards.filter { path, card in
            !found.contains(path) && terms.allSatisfy { card.name.lowercased().contains($0) }
        }.keys
        return paths.compactMap { SearchIndex.lastHit(path: $0) }
            .filter { source == nil || $0.src == source }
    }

    /// Every conversation recorded in a project whose name has all of the query's terms in it, as
    /// their last messages — the way to a project's whole history, listed under the cards that held
    /// it. Not a subagent's or a Codex worker's own transcript (each is part of a conversation that is
    /// listed), and not one whose file is gone, which there would be nothing to resume from.
    nonisolated private static func namedProjectConversations(_ q: String, board: [(path: String, name: String)],
                                                              besides found: Set<String>,
                                                              source: SearchIndex.Source?) -> [SearchIndex.Hit] {
        let terms = SearchIndex.terms(q).map { $0.lowercased() }
        guard terms.joined().count >= 2 else { return [] }
        func matches(_ name: String) -> Bool {
            let name = name.lowercased()
            return terms.allSatisfy { name.contains($0) }
        }
        // By the folder's own name, or by what the board calls the project in that folder.
        let boardNamed = Set(board.filter { matches($0.name) }.map(\.path))
        let projects = SearchIndex.projects().filter {
            boardNamed.contains($0) || matches(($0 as NSString).lastPathComponent)
        }
        let fm = FileManager.default
        return SearchIndex.files(inProjects: projects)
            .filter { path in
                !found.contains(path) && !path.contains("/subagents/") && fm.fileExists(atPath: path)
                    && !CodexTree.isWorkerRollout(path)
            }
            .compactMap { SearchIndex.lastHit(path: $0) }
            .filter { source == nil || $0.src == source }
    }

    /// The card a transcript belongs to. A Claude subagent's transcript is filed under its
    /// conversation (`<sid>/subagents/agent-*.jsonl`) and belongs to whichever card that is. Failing
    /// the path, the conversation id: a reverted Codex thread goes on in a new file under the same
    /// id, and the card was bound to whichever of them it saw.
    nonisolated private static func holder(of path: String, in cards: [String: CommitAuthor],
                                           byId: [String: CommitAuthor]) -> CommitAuthor? {
        if let c = cards[path] { return c }
        let dir = (path as NSString).deletingLastPathComponent
        if (dir as NSString).lastPathComponent == "subagents",
           let c = cards[(dir as NSString).deletingLastPathComponent + ".jsonl"] { return c }
        let id = conversationId(path)
        return id.isEmpty ? nil : byId[id]
    }

    nonisolated private static func conversationId(_ path: String) -> String {
        AgentHome.isCodex(path) ? CodexTree.sessionId(fromRollout: path)
                                : ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// One line, collapsed and windowed onto the first match — a matched prompt is often a wall of
    /// pasted text, and taking the first 240 characters of one regularly showed no match at all.
    ///
    /// Cut down to a few thousand characters around the match before anything else: flattening a
    /// 250 KB log line by line to show 240 characters of it is the work this exists to avoid.
    nonisolated static func snippet(_ body: String, terms: [String]) -> String {
        var text = Substring(body)
        if body.utf16.count > 4000 {
            let at = firstMatch(in: body, terms: terms) ?? body.startIndex
            let from = body.index(at, offsetBy: -1000, limitedBy: body.startIndex) ?? body.startIndex
            let to = body.index(from, offsetBy: 3000, limitedBy: body.endIndex) ?? body.endIndex
            text = body[from..<to]
        }
        let flat = text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
        let cutBefore = text.startIndex > body.startIndex, cutAfter = text.endIndex < body.endIndex
        let width = 240
        guard flat.count > width else {
            return (cutBefore ? "…" : "") + flat + (cutAfter ? "…" : "")
        }
        guard let hit = firstMatch(in: flat, terms: terms) else { return String(flat.prefix(width)) + "…" }
        let lead = 60
        var start = flat.index(hit, offsetBy: -lead, limitedBy: flat.startIndex) ?? flat.startIndex
        if flat.distance(from: start, to: flat.endIndex) < width {
            start = flat.index(flat.endIndex, offsetBy: -width)
        }
        let end = flat.index(start, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex || cutBefore ? "…" : "") + flat[start..<end]
            + (end < flat.endIndex || cutAfter ? "…" : "")
    }

    nonisolated static func firstMatch(in text: String, terms: [String]) -> String.Index? {
        terms.compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }.min()
    }

    /// Removed terminals, as search results.
    ///
    /// Built as `Hit`s and pushed through the same grouping the index feeds, so the panel renders
    /// them, previews them and — the point of doing it this way — drags them onto the board with
    /// the code that already works. A drawer of its own had to re-implement that drag, and did it
    /// wrong: inside the board's ScrollView a plain gesture loses to the scroll.
    ///
    /// The hit is the transcript's last node, which is what resuming a whole conversation means
    /// when what you are holding is a file rather than a search result. It is not what the row
    /// shows: the list draws the card the group carries, and the hit is what the right side reads.
    private func runArchiveSearch(_ q: String) {
        guard let app else { groups = []; projectGroups = []; total = 0; return }
        let rows = archiveProject.map { app.archived(inProject: $0) } ?? app.terminalArchive
        let needle = q.lowercased()
        let matched = needle.isEmpty ? rows : rows.filter {
            $0.name.lowercased().contains(needle) || $0.lastPrompt.lowercased().contains(needle)
        }
        // One row per transcript, newest first.
        //
        // Two cards can share a transcript: restoring one from here resumes the same session, and
        // removing that card archives a second row pointing at the same file. Left alone, the same
        // path is looked up twice and yields two hits with the *same* rowid — `group` merges them
        // into one session holding duplicate ids, and a ForEach over duplicate ids is undefined.
        // The card shown would also have been decided by whichever row happened to be last.
        //
        // (Two cards merely sharing a *name* need none of this: their ids and transcripts differ,
        // so they are two rows that happen to read alike, which is what they are.)
        var cards: [String: TerminalArchive] = [:]
        var paths: [String] = []
        for r in matched.sorted(by: { $0.removedAt > $1.removedAt }) {
            guard let p = r.transcriptPath, cards[p] == nil else { continue }
            cards[p] = r
            paths.append(p)
        }
        failure = nil
        let started = Date()
        Task.detached(priority: .userInitiated) {
            let hits = paths.compactMap { SearchIndex.lastHit(path: $0) }
            // Built immutably: a `var` mutated inside a detached task is an error under Swift 6.
            let sessions = Self.group(hits).map { g -> Group in
                var carded = g
                carded.card = cards[g.id]
                return carded
            }
            let ms = Date().timeIntervalSince(started) * 1000
            await MainActor.run { [weak self] in
                guard let self, self.mode == .archive else { return }
                self.groups = sessions
                self.projectGroups = self.byProject(sessions)
                self.total = hits.count
                self.truncated = false
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
        if projectGroups.count == 1 { expandedProjects = [projectGroups[0].id] }
        else { expandedProjects.formIntersection(projectGroups.map(\.id)) }
        expandedCards.formIntersection(projectGroups.flatMap(\.cards).map(\.id))
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

    /// Sessions rolled up under the project they ran in, newest first all the way down: projects by
    /// their newest hit, and each project's hits by time. Relevance still decides which hits make
    /// the cut (the index returns the best `limit`); time decides the order, because "the one from
    /// last Tuesday" is how a conversation is remembered, and BM25 order scattered one week's
    /// work across the list.
    private func byProject(_ sessions: [Group]) -> [ProjectGroup] {
        let sessions = sessions.map { s -> Group in
            var s = s
            s.hits.sort { $0.ts > $1.ts }
            return s
        }
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
                                        name: key == "—" ? L(.unknownProject) : (key as NSString).lastPathComponent,
                                        sessions: [s], fleet: [], count: s.hits.count)
            }
        }
        return order.compactMap { key -> ProjectGroup? in
            guard var g = acc[key] else { return nil }
            g.sessions.sort { ($0.hits.first?.ts ?? "") > ($1.hits.first?.ts ?? "") }
            g.newest = g.sessions.first?.hits.first?.ts ?? ""
            g.byName = g.sessions.contains { $0.byProjectName }
            g.cards = byCard(g)
            return g
        }
        .sorted { $0.newest > $1.newest }
    }

    /// A project's conversations under the cards that held them (see `ProjectGroup.cards`), newest
    /// card first; the ones no card held go last, together. Archive mode never gets here with more
    /// than one row per card, and its rows are the cards already.
    private func byCard(_ p: ProjectGroup) -> [CardGroup] {
        guard folds else { return [] }
        var order: [String] = []
        var acc: [String: CardGroup] = [:]
        for s in p.sessions {                         // already newest first
            let key = s.holder?.id.uuidString ?? ""
            if var c = acc[key] {
                c.sessions.append(s)
                c.count += s.hits.count
                acc[key] = c
            } else {
                order.append(key)
                acc[key] = CardGroup(id: p.id + "|" + key, holder: s.holder, sessions: [s],
                                     count: s.hits.count, newest: s.hits.first?.ts ?? "")
            }
        }
        let cards = order.filter { !$0.isEmpty }.compactMap { acc[$0] } + (acc[""].map { [$0] } ?? [])
        if p.byName { return cards }
        guard cards.count > 1, cards.contains(where: { $0.count > 1 }) else { return [] }
        return cards
    }

    // MARK: - Preview

    /// A hit with the conversation around it. Reading costs nothing; only opening writes.
    struct Preview: Identifiable {
        let id: Int64
        let hit: SearchIndex.Hit
        let context: [SearchIndex.Hit]
        /// Each message as it is drawn — cut to length, Markdown read, terms marked — worked out
        /// once, off the main thread. Done in the row, it was done again on every redraw, and the
        /// pointer moving over a message is a redraw: with a 250 KB paste in view, browsing hung
        /// the app for 23 seconds until it was force-quit (the hang reports of 2026-11-02).
        let texts: [Int64: AttributedString]
        /// The part of `context` on screen. A conversation runs to thousands of messages, and a lazy
        /// stack asked to scroll to the middle of thousands of rows of differing height lays out
        /// what lies before it to find out where that is. More is a click at either end.
        var shown: Range<Int>
    }

    /// How many messages either side of the hit a preview shows at first, and adds per click.
    nonisolated static let previewStep = 120

    @Published var preview: Preview?

    /// The row selected in the list ("f:<uuid>" or "h:<hit id>"); the right side shows it.
    @Published var selectedKey: String?

    /// Back to an empty field on the board's own terminals. Closing search used to keep the query,
    /// the mode, the preview and a project-scoped "已移除" list, so the next ⌘K opened on whatever
    /// you had last looked at instead of on a field ready for a new question.
    func reset() {
        book = nil
        preview = nil
        selectedKey = nil
        failure = nil
        archiveProject = nil
        query = ""
        mode = .fleet
    }

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
        let query = self.query
        Task.detached(priority: .userInitiated) {
            let context = SearchIndex.context(around: hit)
            let first = Self.render(context, hit: hit, query: query)
            await MainActor.run { [weak self] in
                guard let self, current?.id == self.preview?.id else { return }
                self.preview = Preview(id: hit.id, hit: hit, context: context, texts: first,
                                       shown: 0..<context.count)
            }
            let whole = SearchIndex.conversation(of: hit)
            // Already the whole thing — or the hit is older than the part of a long one that is
            // kept, and the window around it is all there is to show.
            guard whole.count > context.count, let at = whole.firstIndex(where: { $0.id == hit.id })
            else { return }
            let step = Self.previewStep
            let shown = max(0, at - step)..<min(whole.count, at + step + 1)
            var texts = first
            texts.merge(Self.render(whole[shown].filter { first[$0.id] == nil }, hit: hit, query: query)) { a, _ in a }
            let ready = texts
            await MainActor.run { [weak self] in
                guard let self, self.preview?.id == hit.id else { return }
                self.preview = Preview(id: hit.id, hit: hit, context: whole, texts: ready, shown: shown)
            }
        }
    }

    /// Show `previewStep` more messages before (`earlier`) or after the ones on screen. Rendered off
    /// the main thread like the first ones, then added.
    func showMore(earlier: Bool) {
        guard let p = preview else { return }
        let step = Self.previewStep
        let more = earlier ? max(0, p.shown.lowerBound - step)..<p.shown.lowerBound
                           : p.shown.upperBound..<min(p.context.count, p.shown.upperBound + step)
        guard !more.isEmpty else { return }
        let msgs = Array(p.context[more]), hit = p.hit, query = self.query
        Task.detached(priority: .userInitiated) {
            let texts = Self.render(msgs, hit: hit, query: query)
            await MainActor.run { [weak self] in
                guard let self, let now = self.preview, now.id == p.id else { return }
                self.preview = Preview(id: now.id, hit: now.hit, context: now.context,
                                       texts: now.texts.merging(texts) { a, _ in a },
                                       shown: min(now.shown.lowerBound, more.lowerBound)
                                           ..< max(now.shown.upperBound, more.upperBound))
            }
        }
    }

    /// The longest a message is drawn: past a dozen lines it is cut off on screen anyway, and the hit
    /// itself, drawn whole, still has to stay something the text system lays out in a moment.
    nonisolated private static let messageCap = 1_500, hitCap = 8_000

    nonisolated private static func render(_ msgs: [SearchIndex.Hit], hit: SearchIndex.Hit,
                                           query: String) -> [Int64: AttributedString] {
        let terms = SearchIndex.terms(query)
        var out: [Int64: AttributedString] = [:]
        for m in msgs {
            let isHit = m.id == hit.id
            let body = clip(m.body, around: isHit ? terms : [], cap: isHit ? hitCap : messageCap)
            out[m.id] = markdownText(body, query: query,
                                     base: m.role == .user ? Theme.onPrimaryContainer : Theme.onSurface)
        }
        return out
    }

    /// At most `cap` characters of a message, from the start or — when it has a match — from a
    /// little before the first one, so a hit deep in a long paste still shows what matched.
    nonisolated private static func clip(_ body: String, around terms: [String], cap: Int) -> String {
        guard body.utf16.count > cap else { return body }
        var from = body.startIndex
        if let at = firstMatch(in: body, terms: terms) {
            from = body.index(at, offsetBy: -cap / 4, limitedBy: body.startIndex) ?? body.startIndex
        }
        let to = body.index(from, offsetBy: cap, limitedBy: body.endIndex) ?? body.endIndex
        return (from > body.startIndex ? "…" : "") + body[from..<to] + (to < body.endIndex ? " …" : "")
    }

    func closePreview() { preview = nil }

    // MARK: - Open

    /// The conversation back as it stands now — at its newest message, in the card that held it —
    /// rather than at the hit.
    ///
    /// The path `project-manager restore` takes (`AppState.restoreConversation`): a card already
    /// showing it is raised, since a second agent on one session would fight the first for the
    /// transcript; a closed one is reopened; a removed one comes back under its own name and uuid;
    /// only failing all of those is a new card made. Nothing is forked — the newest message is the
    /// session's own tip, and a plain `--resume` lands there.
    func resumeLatest(_ hit: SearchIndex.Hit, in state: AppState) {
        guard opening == nil else { return }
        opening = hit.id
        openingLatest = true
        failure = nil
        Task.detached(priority: .userInitiated) {
            let found = Self.latestFile(of: hit)      // a Codex lookup walks every rollout
            await MainActor.run {
                self.opening = nil
                self.openingLatest = false
                guard let found else { self.failure = L(.searchNoLatest); return }
                let (status, body) = state.restoreConversation(path: found.path, sid: found.sid,
                                                               newName: SearchOpen.label(hit))
                if status.hasPrefix("200") {
                    self.preview = nil
                    state.closeSearch()
                } else {
                    self.failure = (body["error"] as? String) ?? status
                    FV.log("search resume-latest failed: \(status) \(self.failure ?? "")")
                }
            }
        }
    }

    /// The file a conversation continues in, which is not always the one the hit was read from.
    ///
    /// A subagent's transcript is filed under its conversation (`<sid>/subagents/agent-*.jsonl`),
    /// and resuming *it* would bring back the subagent rather than the card. A reverted Codex
    /// thread is several files under one id, and it carries on in the newest
    /// (`AppState.conversationFile` knows which).
    nonisolated private static func latestFile(of hit: SearchIndex.Hit) -> (path: String, sid: String)? {
        let fm = FileManager.default
        func stem(_ p: String) -> String { ((p as NSString).lastPathComponent as NSString).deletingPathExtension }
        switch hit.src {
        case .claude:
            let dir = URL(fileURLWithPath: hit.path).deletingLastPathComponent()
            if dir.lastPathComponent == "subagents" {
                let main = dir.deletingLastPathComponent().path + ".jsonl"
                if fm.fileExists(atPath: main) { return (main, stem(main)) }
            }
            return fm.fileExists(atPath: hit.path) ? (hit.path, stem(hit.path)) : nil
        case .codex:
            let sid = CodexTree.sessionId(fromRollout: hit.path)
            if !sid.isEmpty, case .found(let p, let s) = AppState.conversationFile(sid.lowercased()) {
                return (p, s)
            }
            return fm.fileExists(atPath: hit.path) ? (hit.path, sid) : nil
        }
    }

    /// Resolve a hit into a resumed terminal. Runs the fork off the main actor — synthesising a
    /// long chain takes hundreds of milliseconds, and for a big Codex rollout several seconds.
    func open(_ hit: SearchIndex.Hit, in state: AppState, joinClusterOf card: UUID? = nil) {
        guard opening == nil else { return }
        opening = hit.id
        openingLatest = false
        failure = nil
        let subPool = state.subPool(forConversation: hit)
        Task.detached(priority: .userInitiated) {
            do {
                let plan = try SearchOpen.plan(for: hit, subPool: subPool)
                await MainActor.run {
                    self.preview = nil
                    state.openSearchPlan(plan, hit: hit, joinClusterOf: card)
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
