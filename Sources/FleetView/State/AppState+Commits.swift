import FleetViewFiles
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
        CommitLedger.refresh(roots: Self.commitLedgerRoots, done: done)
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
        for b in AuditTranscripts.bindings() { out[b.path] = author(b.terminal, b.name, b.project, b.cwd) }
        for r in book.removed { if let p = r.path { out[p] = author(r.id, r.name, r.projectId, r.cwd) } }
        for l in book.live { for p in l.paths { out[p] = author(l.id, l.name, l.projectId, l.cwd) } }
        return out
    }

    /// The conversations a card has had (see `cardsByTranscript`).
    nonisolated static func transcripts(ofCard id: UUID, _ book: CardBook,
                                        bindings: [AuditTranscripts.Binding]? = nil) -> [String] {
        var paths = Set((bindings ?? AuditTranscripts.bindings()).filter { $0.terminal == id }.map(\.path))
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

    /// How many commits each card on the board has made: the commits its calls landed on, every
    /// repository counted. Called after the ledger has caught up.
    func refreshCommitCounts() {
        let book = cardBook()
        Task.detached(priority: .utility) { [weak self] in
            let bindings = AuditTranscripts.bindings()
            var counts: [UUID: Int] = [:]
            for card in book.live {
                let calls = CommitLedger.calls(inTranscripts: AppState.transcripts(ofCard: card.id, book, bindings: bindings))
                var made = Set<String>()
                for c in CommitLedger.listable(calls) { made.formUnion(CommitMatches.made(by: c)) }
                if !made.isEmpty { counts[card.id] = made.count }
            }
            await MainActor.run { [weak self] in
                if let self, self.cardCommitCounts != counts { self.cardCommitCounts = counts }
            }
        }
    }
}

/// The commits one call landed on, remembered once the call is over — which commits went in during
/// a span that has ended does not change, so each finished call costs one `git log`, once.
///
/// A count, not a verdict: two cards committing to one repository in the same seconds would both
/// count the pair. Their lists (FileBrowserModel+Commits) weigh the calls against each other.
enum CommitMatches {
    private static let lock = NSLock()
    private static var done: [String: [String]] = [:]

    static func made(by c: CommitLedger.Call) -> [String] {
        lock.lock()
        let hit = done[c.id]
        lock.unlock()
        if let hit { return hit }
        guard let repo = GitReader.shared.repo(at: c.top) else { return [] }
        let w = c.window
        let found = GitReader.shared.commits(repo, from: w.lowerBound, to: w.upperBound, limit: 50)
            .filter { (!c.sha.isEmpty && $0.sha.hasPrefix(c.sha)) || w.contains($0.committed) }.map(\.sha)
        // Kept only once the span is safely over: a call still running may commit yet.
        if let end = c.end, end.timeIntervalSinceNow < -30 {
            lock.lock(); done[c.id] = found; lock.unlock()
        }
        return found
    }
}

/// Every conversation the audit log saw bound to a card. The logs run to hundreds of megabytes, so
/// the lines are found by byte search, each file is read once, and only a file that has grown since
/// (today's) is read again.
enum AuditTranscripts {
    struct Binding: Sendable { let terminal: UUID; let name: String; let project: UUID?; let cwd: String?; let path: String }

    private static let lock = NSLock()
    private static var cache: [String: (size: Int, bindings: [Binding])] = [:]

    static func bindings() -> [Binding] {
        let dir = FV.logsDir
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("audit-") && $0.hasSuffix(".jsonl") }.sorted()
        var out: [Binding] = []
        for f in files {
            let path = dir.appendingPathComponent(f).path
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
            lock.lock()
            let hit = cache[f]
            lock.unlock()
            if let hit, hit.size == size { out += hit.bindings; continue }
            let read = parse(path)
            lock.lock(); cache[f] = (size, read); lock.unlock()
            out += read
        }
        return out
    }

    private static func parse(_ path: String) -> [Binding] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let needle = Data("\"fleetview.terminal.transcript_bound\"".utf8)
        var out: [Binding] = []
        var start = data.startIndex
        while start < data.endIndex, let hit = data.range(of: needle, in: start..<data.endIndex) {
            let lineStart = data[..<hit.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let lineEnd = data[hit.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            start = lineEnd
            guard let r = try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd]) as? [String: Any],
                  let target = r["fleetview.target"] as? [String: Any],
                  let id = (target["terminal.id"] as? String).flatMap(UUID.init(uuidString:)),
                  let to = (r["fleetview.data"] as? [String: Any])?["transcript.to"] as? String else { continue }
            out.append(Binding(terminal: id, name: target["terminal.name"] as? String ?? "",
                               project: (target["project.id"] as? String).flatMap(UUID.init(uuidString:)),
                               cwd: target["terminal.cwd"] as? String, path: AgentHome.canonical(to)))
        }
        return out
    }
}
