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
extension FileBrowserModel {

    /// The project's own repository and its worktrees, and the repositories inside it: a commit
    /// made in any of these shows in this window already.
    nonisolated private static func homeTops(_ repos: [RepoRef]) -> Set<String> {
        var tops = Set<String>()
        for r in repos where !r.isExternal {
            tops.insert(r.repo.toplevel)
            tops.formUnion(GitReader.shared.worktrees(r.repo))
        }
        return tops
    }

    private func ledgerUpToDate() async {
        guard let app else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            app.refreshCommitLedger { c.resume() }
        }
    }

    /// Credit the commits listed to the cards that made them.
    func attributeCommits() {
        guard let r = repo(folder: historyRepo), let app, !commits.isEmpty else { commitAuthors = [:]; return }
        authorsGeneration += 1
        let gen = authorsGeneration
        let list = commits.map { (sha: $0.sha, committed: $0.committed) }
        let book = app.cardBook()
        Task {
            await ledgerUpToDate()
            let found = await onUtility { () -> [String: CommitAuthor] in
                guard let from = list.map(\.committed).min(), let to = list.map(\.committed).max() else { return [:] }
                let calls = GitReader.shared.worktrees(r.repo).flatMap { CommitLedger.calls(inRepo: $0, from: from, to: to) }
                let cards = AppState.cardsByTranscript(book)
                return CommitLedger.attribute(list, to: calls).compactMapValues { cards[$0.transcript] }
            }
            guard gen == self.authorsGeneration else { return }
            self.commitAuthors = found
        }
    }

    /// This project's cards that have committed, and the repositories outside it they committed to.
    func loadCommitters() {
        guard let app else { return }
        let book = app.cardBook()
        let pid = projectId, root = self.root, home = repos
        Task {
            await ledgerUpToDate()
            let (people, outside) = await onUtility { () -> ([CommitAuthor], [GitReader.Repo]) in
                let removedHere = Set(book.removed.filter { $0.projectId == pid || $0.projectPath == root }.map(\.id))
                let cards = AppState.cardsByTranscript(book)
                let mine = cards.filter { $0.value.projectId == pid || removedHere.contains($0.value.id) || $0.value.works(in: root) }
                let calls = CommitLedger.listable(CommitLedger.calls(inTranscripts: Array(mine.keys)))
                // Newest first, cards on the board before removed ones.
                var last: [UUID: Date] = [:]
                for c in calls { if let a = mine[c.transcript] { last[a.id] = max(last[a.id] ?? .distantPast, c.start) } }
                let people = Set(mine.values.filter { last[$0.id] != nil })
                    .sorted { ($0.removed ? 1 : 0, last[$1.id]!) < ($1.removed ? 1 : 0, last[$0.id]!) }
                let tops = Self.homeTops(home)
                var seen = Set<String>(), outside: [GitReader.Repo] = []
                for c in calls where !tops.contains(c.top) && seen.insert(c.top).inserted {
                    if let r = GitReader.shared.repo(at: c.top), !tops.contains(r.toplevel) { outside.append(r) }
                    if outside.count >= 20 { break }
                }
                return (people, outside)
            }
            self.committers = people
            // Kept when already listed, so one being read is not replaced under it.
            let have = Set(self.externalRepos.map(\.folder))
            self.externalRepos += outside.filter { !have.contains($0.toplevel) }
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
        let home = repos
        Task {
            await ledgerUpToDate()
            let found = await onUtility { () -> [(commit: GitCommit, repo: GitReader.Repo)] in
                let paths = AppState.transcripts(ofCard: card.id, book)
                let calls = CommitLedger.listable(CommitLedger.calls(inTranscripts: paths))
                var out: [(commit: GitCommit, repo: GitReader.Repo)] = []
                var seen = Set<String>()
                for (top, mine) in Dictionary(grouping: calls, by: \.top) {
                    guard let repo = GitReader.shared.repo(at: top) else { continue }
                    let trees = GitReader.shared.worktrees(repo)
                    for c in mine {
                        let w = c.window
                        let candidates = GitReader.shared.commits(repo, from: w.lowerBound, to: w.upperBound, limit: 50)
                        guard !candidates.isEmpty else { continue }
                        // Weighed against every call in that repository at the time — another card
                        // committing in the same seconds keeps its own commit.
                        let rivals = trees.flatMap { CommitLedger.calls(inRepo: $0, from: w.lowerBound, to: w.upperBound) }
                        let made = CommitLedger.attribute(candidates.map { (sha: $0.sha, committed: $0.committed) },
                                                          to: rivals.contains(c) ? rivals : rivals + [c])
                        for m in candidates where made[m.sha]?.id == c.id && seen.insert(m.sha).inserted {
                            out.append((m, repo))
                        }
                    }
                }
                return out.sorted { $0.commit.committed > $1.commit.committed }
            }
            let tops = await onUtility { Self.homeTops(home) }
            guard gen == self.authorsGeneration else { return }
            var list: [CardCommit] = []
            for f in found {
                list.append(CardCommit(commit: f.commit, repoFolder: self.folder(for: f.repo, home: tops)))
            }
            self.cardCommits = list
            self.cardCommitsLoading = false
        }
    }

    func clearCardFilter() {
        historyCard = nil
        cardCommits = []
        cardCommitsLoading = false
    }

    /// Where a repository the ledger names sits in this window: the project's own (its worktrees
    /// share its commits), one found inside the project, or one outside it — listed from now on.
    private func folder(for repo: GitReader.Repo, home: Set<String>) -> String {
        let top = repo.toplevel
        if let n = nested.first(where: { $0.repo.toplevel == top }) { return n.folder }
        if home.contains(top), let m = mainRef { return m.folder }
        if let e = externalRepos.first(where: { $0.repo.toplevel == top }) { return e.folder }
        externalRepos.append(RepoRef(repo: repo, folder: top, rootInRepo: ""))
        return top
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
