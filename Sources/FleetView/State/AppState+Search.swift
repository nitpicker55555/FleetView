import Foundation

/// Opening a search hit: the "search" half lives in SearchIndex/SearchOpen, this is the part that
/// has to touch app state — creating the project and the terminal the conversation opens into.
extension AppState {

    func openSearch() {
        searchOpen = true
        // Warm the index while the field is still empty, so the first query is instant.
        searchModel.refreshIndex()
    }

    /// Open the search panel on one project's removed terminals.
    ///
    /// The same panel rather than a drawer of its own: listing them was never the hard part —
    /// dragging one back onto the board is, and that gesture already works here, in the overlay
    /// that floats above the board rather than inside its scroll view.
    func openArchive(projectId: UUID?) {
        searchModel.app = self
        searchModel.query = ""
        searchModel.archiveProject = projectId
        searchModel.mode = .archive
        searchOpen = true
    }

    func closeSearch() { searchOpen = false }

    func toggleSearch() { searchOpen ? closeSearch() : openSearch() }

    /// Land a resolved hit in a fresh terminal.
    ///
    /// Unlike the tree panel's fork-open, there is no "source terminal" to inherit from: a hit can
    /// come from any of the projects on disk, including one FleetView has never opened. So the
    /// project is created on demand — `addProject` already de-duplicates by path, so a known
    /// project is simply selected instead.
    func openSearchPlan(_ plan: SearchOpen.Plan, hit: SearchIndex.Hit,
                        joinClusterOf targetCard: UUID? = nil) {
        let projectId: UUID
        if let existing = projects.first(where: { $0.path == plan.cwd }) {
            projectId = existing.id
        } else {
            addProject(path: plan.cwd)
            guard let created = projects.first(where: { $0.path == plan.cwd }) else {
                FV.log("search open: could not create project for \(plan.cwd)")
                return
            }
            projectId = created.id
        }
        // Dropped onto a card: land in that card's cluster (same rule as a tree-panel drop).
        let clusterId = targetCard.flatMap { ensureCluster(for: $0) }
        let name = inheritedName(for: hit, forked: plan.synthesized) ?? plan.label
        guard let terminal = newTerminal(projectId: projectId, name: name,
                                         clusterId: clusterId, autoRunClaude: false) else {
            FV.log("search open: no terminal for \(plan.cwd)")
            return
        }
        FV.log("search open: \(plan.detail) synthesized=\(plan.synthesized) cwd=\(plan.cwd)")
        // Same delay the fork/duplicate flows use — a fresh tmux session needs a moment to reach
        // a ready shell before anything is typed into it.
        typeIntoTerminal(terminal.id, plan.command, after: 1.4)
        closeSearch()
    }

    /// The name of the card this conversation last lived in, for the card that opens it again.
    ///
    /// A conversation pulled back out of search, or out of the drawer of removed cards, used to
    /// come back as "⌕ " plus the first twelve characters of whichever message was hit, whatever
    /// the card that held it had been called. A card still on the board wins over the drawer, and
    /// newer wins over older. A fork (a node short of the end, written out as a new session) is
    /// marked " ⑂", as a duplicated card is; a plain resume is the same conversation and keeps the
    /// name unchanged. nil when no card ever held it, and the hit's own text is all there is.
    func inheritedName(for hit: SearchIndex.Hit, forked: Bool) -> String? {
        let (live, archived) = holders(of: hit)
        guard let name = live?.name ?? archived?.name, !name.isEmpty else { return nil }
        return forked ? name + " ⑂" : name
    }

    /// What the card that last held this conversation ran, `sp-claude` or `claude`, when one did —
    /// the transcript cannot say when both CLIs file into the same folder (see AgentHome).
    func subPool(forConversation hit: SearchIndex.Hit) -> Bool? {
        let (live, archived) = holders(of: hit)
        return live?.subPool ?? archived?.subPool
    }

    /// The card on the board that last held `hit`'s conversation, and the removed one — a card
    /// still on the board wins over the drawer, and newer wins over older.
    private func holders(of hit: SearchIndex.Hit) -> (TerminalSession?, TerminalArchive?) {
        func same(_ path: String?, _ sid: String?) -> Bool {
            path == hit.path || (!hit.session.isEmpty && sid == hit.session)
        }
        let live = terminals.filter { same($0.transcriptPath, $0.sessionId) }
            .max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
        let archived = terminalArchive.filter { same($0.transcriptPath, $0.sessionId) }
            .max { $0.removedAt < $1.removedAt }
        return (live, archived)
    }
}
