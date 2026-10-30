import Foundation
import FleetViewFiles

/// One of a card's commits, and the repository it went to.
struct CardCommit: Identifiable, Equatable {
    let commit: GitCommit
    /// As `repo(folder:)` names it: "" for the project's own, a folder inside it, or an absolute path.
    let repoFolder: String
    var id: String { repoFolder + "@" + commit.sha }
}

/// Who made each commit, and what each card committed — wherever it went.
///
/// A project is many cards, and a card's agent commits wherever it was told to: the project's own
/// repository, a worktree of it, a sibling checkout. The repository's log cannot say which card made
/// what, so the agents' transcripts are asked (CommitLedger) and each conversation is put back on
/// the card it belonged to (`AppState.cardsByTranscript`). A duplicated card shares its parent's
/// history, and the commits in it stay the parent's.
///
/// Everything here is read from the ledger's file, never from git: what is already written down is
/// shown at once, and shown again once the ledger has caught up with the last few minutes.
extension FileBrowserModel {

    private func ledgerUpToDate() async {
        guard let app else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            app.refreshCommitLedger { c.resume() }
        }
    }

    /// Now from what the ledger has, and again once it has caught up.
    private func twice(_ work: @escaping () async -> Void) {
        Task {
            await work()
            await ledgerUpToDate()
            await work()
        }
    }

    /// Credit the commits listed to the cards that made them.
    func attributeCommits() {
        guard let app, !commits.isEmpty else { commitAuthors = [:]; return }
        authorsGeneration += 1
        let gen = authorsGeneration
        let shas = commits.map(\.sha)
        let book = app.cardBook()
        twice {
            let found = await onUtility { () -> [String: CommitAuthor] in
                let cards = AppState.cardsByTranscript(book)
                return CommitLedger.conversations(of: shas).compactMapValues { cards[$0] }
            }
            guard gen == self.authorsGeneration else { return }
            if found != self.commitAuthors { self.commitAuthors = found }
        }
    }

    /// The conversations of this project's cards, and the cards by conversation.
    nonisolated private static func projectCards(_ book: AppState.CardBook, project pid: UUID, root: String)
        -> [String: CommitAuthor] {
        let removedHere = Set(book.removed.filter { $0.projectId == pid || $0.projectPath == root }.map(\.id))
        return AppState.cardsByTranscript(book)
            .filter { $0.value.projectId == pid || removedHere.contains($0.value.id) || $0.value.works(in: root) }
    }

    /// Whether a repository the ledger names is this window's own: the project's repository or a
    /// worktree of it (they share its commits), or one found inside the project.
    private func isHome(_ top: String, common: [String: String]) -> Bool {
        if nested.contains(where: { $0.repo.toplevel == top }) { return true }
        guard let m = mainRef else { return false }
        return top == m.repo.toplevel || (common[top].map { !$0.isEmpty && $0 == m.repo.commonDir } ?? false)
    }

    /// This project's cards that have committed, and the repositories outside it they committed to.
    func loadCommitters() {
        guard let app else { return }
        let book = app.cardBook()
        let pid = projectId, root = self.root
        twice {
            let (people, tops, common) = await onUtility { () -> ([CommitAuthor], [String], [String: String]) in
                let mine = Self.projectCards(book, project: pid, root: root)
                let made = CommitLedger.made(inTranscripts: Array(mine.keys)).filter { !CommitLedger.isScratch($0.top) }
                // Newest first, cards on the board before removed ones.
                var last: [UUID: Date] = [:]
                for m in made { if let a = mine[m.transcript] { last[a.id] = max(last[a.id] ?? .distantPast, m.committed) } }
                let people = Set(mine.values.filter { last[$0.id] != nil })
                    .sorted { ($0.removed ? 1 : 0, last[$1.id]!) < ($1.removed ? 1 : 0, last[$0.id]!) }
                var seen = Set<String>()
                return (people, made.map(\.top).filter { seen.insert($0).inserted }, CommitLedger.commonDirs())
            }
            self.committers = people
            let have = Set(self.externalRepos.map(\.folder))
            let outside = Array(tops.filter { !self.isHome($0, common: common) && !have.contains($0) }.prefix(20))
            guard !outside.isEmpty else { return }
            let repos = await onUtility { outside.compactMap { GitReader.shared.repo(at: $0) } }
            // Kept when already listed, so one being read is not replaced under it.
            let now = Set(self.externalRepos.map(\.folder))
            self.externalRepos += repos.filter { !now.contains($0.toplevel) }
                .map { RepoRef(repo: $0, folder: $0.toplevel, rootInRepo: "") }
        }
    }

    /// List one card's commits, across every repository it committed to.
    func showCommits(of card: CommitAuthor) {
        historyCard = card
        cardCommits = []
        cardCommitsLoading = true
        if sideMode != .history { sideMode = .history }
        guard let app else { cardCommitsLoading = false; return }
        authorsGeneration += 1
        let gen = authorsGeneration
        let book = app.cardBook()
        twice {
            let (made, common) = await onUtility { () -> ([CommitLedger.Made], [String: String]) in
                let mine = CommitLedger.made(inTranscripts: AppState.transcripts(ofCard: card.id, book))
                var seen = Set<String>()
                return (mine.filter { !CommitLedger.isScratch($0.top) && seen.insert($0.sha).inserted },
                        CommitLedger.commonDirs())
            }
            guard gen == self.authorsGeneration else { return }
            // A repository outside the project gets its place in the menu first, so its commits open.
            let unknown = Set(made.map(\.top)).filter { top in
                !self.isHome(top, common: common) && !self.externalRepos.contains { $0.repo.toplevel == top }
            }
            if !unknown.isEmpty {
                let repos = await onUtility { unknown.compactMap { GitReader.shared.repo(at: $0) } }
                guard gen == self.authorsGeneration else { return }
                self.externalRepos += repos.filter { r in !self.externalRepos.contains { $0.folder == r.toplevel } }
                    .map { RepoRef(repo: $0, folder: $0.toplevel, rootInRepo: "") }
            }
            let list = made.map { m in
                CardCommit(commit: GitCommit(sha: m.sha, author: m.author, date: m.committed, committed: m.committed,
                                             subject: m.subject),
                           repoFolder: self.folder(forTop: m.top, common: common))
            }
            if list != self.cardCommits { self.cardCommits = list }
            self.cardCommitsLoading = false
        }
    }

    func clearCardFilter() {
        historyCard = nil
        cardCommits = []
        cardCommitsLoading = false
    }

    /// Where a repository the ledger names sits in this window: the project's own, one found inside
    /// the project, or one outside it.
    private func folder(forTop top: String, common: [String: String]) -> String {
        if let n = nested.first(where: { $0.repo.toplevel == top }) { return n.folder }
        if isHome(top, common: common), let m = mainRef { return m.folder }
        return externalRepos.first { $0.repo.toplevel == top }?.folder ?? top
    }

    /// A card as the page's card menu and chips name it: a removed one says so.
    func authorName(_ a: CommitAuthor) -> String {
        a.removed ? L(.histCardRemoved(a.name)) : a.name
    }

    /// A repository's name in the page's menus.
    func repoName(_ r: RepoRef) -> String {
        if r.isExternal { return "↗ " + (r.folder as NSString).lastPathComponent }
        return r.folder.isEmpty ? projectName : r.folder
    }
}
