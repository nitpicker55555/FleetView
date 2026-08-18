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
    func openSearchPlan(_ plan: SearchOpen.Plan, joinClusterOf targetCard: UUID? = nil) {
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
        guard let terminal = newTerminal(projectId: projectId, name: plan.label,
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
}
