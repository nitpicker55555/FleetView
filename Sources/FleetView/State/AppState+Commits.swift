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

    /// For the git chip on each card: how many commits it has made, every repository counted (read
    /// from the ledger alone), and how many files it wrote that are still uncommitted.
    func refreshCommitCounts() {
        let book = cardBook()
        Task.detached(priority: .utility) { [weak self] in
            let cards = AppState.cardsByTranscript(book)
            var made: [UUID: Set<String>] = [:]
            for m in CommitLedger.allMade() {
                if let a = cards[m.transcript], !a.removed { made[a.id, default: []].insert(m.sha) }
            }
            let counts = made.mapValues(\.count)
            let open = AppState.uncommittedCounts(book, cards: cards)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.cardCommitCounts != counts { self.cardCommitCounts = counts }
                if self.cardUncommittedCounts != open { self.cardUncommittedCounts = open }
            }
        }
    }

    /// The files one card wrote that are still uncommitted, by repository: what its agents' Edit and
    /// Write calls (and Codex's patches) touched, against `git status` of each repository they are in.
    /// A file a later card wrote too is that card's. A file changed afterwards by hand still counts as
    /// the last agent's — nothing records the hand. Runs git: call off the main actor.
    nonisolated static func uncommitted(ofCard id: UUID, _ book: CardBook)
        -> [(repo: GitReader.Repo, files: [String], untracked: [String])] {
        let mine = transcripts(ofCard: id, book)
        let written = CommitLedger.edits(inTranscripts: mine)
        var byTop: [String: [String]] = [:]
        for p in written.keys {
            let top = CommitLedger.toplevel((p as NSString).deletingLastPathComponent)
            if !top.isEmpty && !CommitLedger.isScratch(top) { byTop[top, default: []].append(p) }
        }
        var dirty: [(repo: GitReader.Repo, files: [(abs: String, untracked: Bool)])] = []
        for (top, files) in byTop {
            guard let repo = GitReader.shared.repo(at: top), let status = GitReader.shared.status(repo) else { continue }
            let wanted = Set(files)
            var hit: [(abs: String, untracked: Bool)] = []
            for e in status where e.mark != .deleted {
                let abs = repo.toplevel + "/" + e.path
                if e.mark == .untracked && e.path.hasSuffix("/") {
                    // A new folder is one status line; the card's files in it are its own lines here.
                    hit += files.filter { $0.hasPrefix(abs) }.map { ($0, true) }
                } else if wanted.contains(abs) {
                    hit.append((abs, e.mark == .untracked))
                }
            }
            if !hit.isEmpty { dirty.append((repo, hit)) }
        }
        let last = CommitLedger.lastWriters(of: dirty.flatMap { $0.files.map(\.abs) })
        let own = Set(mine)
        return dirty.compactMap { d in
            let kept = d.files.filter { last[$0.abs].map(own.contains) ?? false }
            guard !kept.isEmpty else { return nil }
            let rel = { (abs: String) in String(abs.dropFirst(d.repo.toplevel.count + 1)) }
            return (d.repo, kept.map { rel($0.abs) }.sorted(), kept.filter(\.untracked).map { rel($0.abs) })
        }
    }

    /// `GET /commits?id=`: one card's commits and uncommitted files, as `project-manager commits`
    /// prints them. Runs git and waits on the ledger: call off the main actor.
    nonisolated static func gitReport(card id: UUID, name: String, project: String, _ book: CardBook) -> Data {
        let made = CommitLedger.made(inTranscripts: transcripts(ofCard: id, book))
        var seen = Set<String>()
        let commits: [[String: Any]] = made.filter { !CommitLedger.isScratch($0.top) && seen.insert($0.sha).inserted }.map {
            ["sha": $0.sha, "repo": $0.top, "committed": Int($0.committed.timeIntervalSince1970),
             "author": $0.author, "subject": $0.subject]
        }
        let open: [[String: Any]] = uncommitted(ofCard: id, book).map {
            ["repo": $0.repo.toplevel, "files": $0.files, "untracked": $0.untracked]
        }
        let body: [String: Any] = ["id": id.uuidString, "name": name, "project": project,
                                   "commits": commits, "uncommitted": open]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// A card as the reports name it: its uuid, name, and whether it is still on the board.
    nonisolated private static func cardJSON(_ a: CommitAuthor?) -> [String: Any]? {
        a.map { ["id": $0.id.uuidString, "name": $0.name, "removed": $0.removed] }
    }

    /// Which card's agent wrote a file — or, for a folder, each uncommitted file in it — the latest
    /// writer first. A file no agent wrote (a shell command, a hand) has none. Runs git.
    nonisolated private static func writerRows(path raw: String, cards: [String: CommitAuthor])
        -> (top: String, path: String, rows: [[String: Any]]) {
        let path = (raw as NSString).standardizingPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let top = CommitLedger.toplevel(isDir.boolValue ? path : (path as NSString).deletingLastPathComponent)
        var status: [String: String] = [:]      // absolute path → git's mark
        if !top.isEmpty, let repo = GitReader.shared.repo(at: top), let st = GitReader.shared.status(repo) {
            for e in st {
                let abs = repo.toplevel + "/" + e.path
                if e.mark == .untracked && e.path.hasSuffix("/") {
                    // A new folder is one line to git; its files are listed one by one here — every
                    // one git would add, not only those an agent's Edit wrote. The first version took
                    // them from the ledger alone, and a folder of scripts made by shell commands
                    // (tools/wechat-decrypt) was simply not there.
                    for f in GitReader.shared.untrackedFiles(repo, under: e.path) {
                        status[repo.toplevel + "/" + f] = GitStatus.Mark.untracked.rawValue
                    }
                } else {
                    status[abs] = e.mark.rawValue
                }
            }
        }
        let files = isDir.boolValue
            ? status.keys.filter { $0 == path || $0.hasPrefix(path.hasSuffix("/") ? path : path + "/") }.sorted()
            : [path]
        let writers = CommitLedger.writers(of: files)
        let rows: [[String: Any]] = files.map { f in
            let who: [[String: Any]] = (writers[f] ?? []).map { w in
                var row: [String: Any] = ["at": Int(w.at.timeIntervalSince1970), "transcript": w.transcript]
                if let c = cardJSON(cards[w.transcript]) { row.merge(c) { a, _ in a } }
                return row
            }
            return ["path": top.isEmpty ? f : String(f.dropFirst(top.count + 1)),
                    "status": status[f] ?? (exists || isDir.boolValue ? "clean" : "missing"), "writers": who]
        }
        return (top, path, rows)
    }

    /// `GET /writers?path=`: see `writerRows`. Runs git: call off the main actor.
    nonisolated static func writersReport(path raw: String, _ book: CardBook) -> Data {
        let (top, path, rows) = writerRows(path: raw, cards: cardsByTranscript(book))
        let body: [String: Any] = ["repo": top, "path": path, "files": rows]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// `GET /repo?path=`: a repository seen from its cards — its newest commits, each with the card
    /// that made it, and its uncommitted files, each with the card that wrote it last. `sha` asks
    /// about one commit instead of the newest. Runs git: call off the main actor.
    nonisolated static func repoReport(path raw: String, limit: Int, sha: String?, _ book: CardBook) -> Data {
        let path = (raw as NSString).standardizingPath
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        guard let repo = GitReader.shared.repo(at: isDir.boolValue ? path : (path as NSString).deletingLastPathComponent) else {
            return Data(#"{"error":"not in a git repository"}"#.utf8)
        }
        let cards = cardsByTranscript(book)
        let commits: [GitCommit]
        if let sha {
            guard let c = GitReader.shared.commit(repo, sha) else { return Data(#"{"error":"no such commit"}"#.utf8) }
            commits = [c]
        } else {
            commits = GitReader.shared.log(repo, limit: limit) ?? []
        }
        let made = CommitLedger.conversations(of: commits.map(\.sha))
        let list: [[String: Any]] = commits.map { c in
            var row: [String: Any] = ["sha": c.sha, "committed": Int(c.committed.timeIntervalSince1970),
                                      "author": c.author, "subject": c.subject]
            if let t = made[c.sha] {
                row["transcript"] = t
                if let card = cardJSON(cards[t]) { row["card"] = card }
            }
            return row
        }
        var body: [String: Any] = ["repo": repo.toplevel, "commits": list]
        if sha == nil { body["uncommitted"] = writerRows(path: repo.toplevel, cards: cards).rows }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Each card's uncommitted files, the whole board at once: every file a card on it wrote, against
    /// one `git status` per repository they are in, each dirty file going to the card that wrote it
    /// last. The same rule as a card's own list (FileBrowserModel+Commits).
    nonisolated static func uncommittedCounts(_ book: CardBook, cards: [String: CommitAuthor]) -> [UUID: Int] {
        let bindings = CommitLedger.bindings()
        var written = Set<String>()
        for card in book.live {
            written.formUnion(CommitLedger.edits(inTranscripts: transcripts(ofCard: card.id, book, bindings: bindings)).keys)
        }
        // Each file's repository, found on disk once per folder.
        var topOf: [String: String] = [:]
        var byTop: [String: [String]] = [:]
        for f in written {
            let dir = (f as NSString).deletingLastPathComponent
            let top = topOf[dir] ?? CommitLedger.toplevel(dir)
            topOf[dir] = top
            if !top.isEmpty && !CommitLedger.isScratch(top) { byTop[top, default: []].append(f) }
        }
        var dirty: [String] = []
        for (top, files) in byTop {
            guard let repo = GitReader.shared.repo(at: top), let status = GitReader.shared.status(repo) else { continue }
            let wanted = Set(files)
            for e in status where e.mark != .deleted {
                let abs = repo.toplevel + "/" + e.path
                if e.mark == .untracked && e.path.hasSuffix("/") { dirty += files.filter { $0.hasPrefix(abs) } }
                else if wanted.contains(abs) { dirty.append(abs) }
            }
        }
        var out: [UUID: Int] = [:]
        for (_, transcript) in CommitLedger.lastWriters(of: dirty) {
            if let a = cards[transcript], !a.removed { out[a.id, default: 0] += 1 }
        }
        return out
    }
}
