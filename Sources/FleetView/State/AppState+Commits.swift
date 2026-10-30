import Foundation

/// The card a commit is credited to: the one whose conversation made the call (CommitLedger).
struct CommitAuthor: Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    let projectId: UUID?
    /// No longer on the board — credited all the same, under the name it had.
    let removed: Bool
    /// Where it worked. Which project a card belongs to is also asked of this: a project closed and
    /// opened again gets a new id, and the cards recorded under the old one would belong nowhere.
    var cwd: String? = nil

    func works(in root: String) -> Bool {
        guard let cwd else { return false }
        return cwd == root || cwd.hasPrefix(root + "/")
    }
}

/// Which card each conversation belonged to — the half of "who made this commit" that the ledger
/// cannot know, since it reads transcripts and transcripts do not know about cards.
extension AppState {

    static var commitLedgerRoots: [(url: URL, codex: Bool)] {
        AgentHome.roots(.claude).map { ($0.url, false) } + AgentHome.roots(.codex).map { ($0.url, true) }
    }

    func refreshCommitLedger(done: (() -> Void)? = nil) {
        CommitLedger.refresh(roots: Self.commitLedgerRoots, logs: FV.logsDir, canonical: AgentHome.canonical, done: done)
    }

    /// What the board knows of its cards right now — taken on the main actor, read anywhere.
    struct CardBook: Sendable {
        let live: [(id: UUID, name: String, projectId: UUID, cwd: String, paths: [String])]
        let removed: [(id: UUID, name: String, projectId: UUID, projectPath: String?, cwd: String, path: String?)]
    }

    func cardBook() -> CardBook {
        CardBook(
            live: terminals.map { t in
                (t.id, t.name, t.projectId, t.cwd,
                 [hookSessionPath(for: t.id), t.transcriptPath].compactMap { $0 }.map(AgentHome.canonical))
            },
            removed: terminalArchive.map { ($0.id, $0.name, $0.projectId, $0.projectPath, $0.cwd,
                                            $0.transcriptPath.map(AgentHome.canonical)) })
    }

    /// Every conversation each card has had, by path. A card goes through several — a `/clear`, a
    /// reopen that could not resume — and the board keeps only the last; the audit log has each one
    /// bound to it (`transcript_bound`). The board's own answer wins where they disagree, then the
    /// drawer's. Names are the card's current one where it still has one.
    nonisolated static func cardsByTranscript(_ book: CardBook) -> [String: CommitAuthor] {
        var out: [String: CommitAuthor] = [:]
        let liveIds = Dictionary(book.live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let removedIds = Dictionary(book.removed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func author(_ id: UUID, _ name: String, _ project: UUID?, _ cwd: String?) -> CommitAuthor {
            if let l = liveIds[id] { return CommitAuthor(id: id, name: l.name, projectId: l.projectId, removed: false, cwd: l.cwd) }
            if let r = removedIds[id] { return CommitAuthor(id: id, name: r.name, projectId: r.projectId, removed: true, cwd: r.cwd) }
            return CommitAuthor(id: id, name: name, projectId: project, removed: true, cwd: cwd)
        }
        for b in CommitLedger.bindings() { out[b.path] = author(b.terminal, b.name, b.project, b.cwd) }
        for r in book.removed { if let p = r.path { out[p] = author(r.id, r.name, r.projectId, r.cwd) } }
        for l in book.live { for p in l.paths { out[p] = author(l.id, l.name, l.projectId, l.cwd) } }
        return out
    }

    /// The conversations a card has had (see `cardsByTranscript`).
    nonisolated static func transcripts(ofCard id: UUID, _ book: CardBook,
                                        bindings: [CommitLedger.Binding]? = nil) -> [String] {
        var paths = Set((bindings ?? CommitLedger.bindings()).filter { $0.terminal == id }.map(\.path))
        for r in book.removed where r.id == id { if let p = r.path { paths.insert(p) } }
        for l in book.live where l.id == id { paths.formUnion(l.paths) }
        return Array(paths)
    }
}

extension AppState {
    /// Count each card's commits again, soon: a turn just ended, and its agent may have committed.
    func scheduleCommitCounts() {
        commitCountWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshCommitLedger { Task { @MainActor [weak self] in self?.refreshCommitCounts() } }
        }
        commitCountWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// How many commits each card on the board has made, every repository counted — read from the
    /// ledger alone, which has already matched each call to its commits.
    func refreshCommitCounts() {
        let book = cardBook()
        Task.detached(priority: .utility) { [weak self] in
            let cards = AppState.cardsByTranscript(book)
            var made: [UUID: Set<String>] = [:]
            for m in CommitLedger.allMade() {
                if let a = cards[m.transcript], !a.removed { made[a.id, default: []].insert(m.sha) }
            }
            let counts = made.mapValues(\.count)
            await MainActor.run { [weak self] in
                if let self, self.cardCommitCounts != counts { self.cardCommitCounts = counts }
            }
        }
    }
}
