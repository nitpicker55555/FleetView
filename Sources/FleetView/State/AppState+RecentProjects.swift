import Foundation

/// A folder that has been a project on the board, and when it was last used there.
///
/// The board forgets a project the moment it is closed: `projects` is only what is open now, so
/// getting last week's project back meant finding its folder again in the open panel. This is the
/// memory of it. Keyed by path, because a project's id does not survive a close and reopen —
/// `addProject` mints a fresh one for the same folder.
///
/// In state.json, so anything added to it later has to be Optional (CLAUDE.md).
struct RecentProject: Codable, Hashable {
    var path: String
    var name: String
    var lastUsed: Date
}

/// One line of the toolbar's recent-projects menu.
struct RecentProjectRow: Identifiable, Hashable {
    let path: String
    let name: String
    let lastUsed: Date?
    /// Removed cards with a conversation behind them: the count the project's 🗃 button shows.
    let history: Int
    /// Set while the project is on the board.
    let projectId: UUID?
    var id: String { path }
}

extension AppState {
    static let recentProjectsCap = 200

    struct ProjectUsage {
        var lastUsed: Date?
        var history = 0
    }

    /// Opening a project counts as using it, now — opening one already on the board included,
    /// since that is someone going back to it.
    func noteProjectOpened(path: String, name: String) {
        rememberProject(path: path, name: name, at: Date())
    }

    /// A project on its way off the board keeps the time its cards were last active, not "now":
    /// closing is putting it away, not working in it — and clearing the board would otherwise stamp
    /// every project with the same instant and throw away the order they were used in. Only a
    /// project with no activity and no record falls back to now, so it is not forgotten outright.
    func noteProjectClosing(_ p: Project) {
        let activity = terminals(inProject: p.id).compactMap(\.lastActivity).max()
        if activity == nil, recentProjects.contains(where: { $0.path == p.path }) { return }
        rememberProject(path: p.path, name: p.name, at: activity ?? Date())
    }

    private func rememberProject(path: String, name: String, at: Date) {
        if let i = recentProjects.firstIndex(where: { $0.path == path }) {
            recentProjects[i].name = name
            recentProjects[i].lastUsed = max(recentProjects[i].lastUsed, at)
        } else {
            recentProjects.append(RecentProject(path: path, name: name, lastUsed: at))
        }
        if recentProjects.count > Self.recentProjectsCap {
            recentProjects.sort { $0.lastUsed > $1.lastUsed }
            recentProjects.removeLast(recentProjects.count - Self.recentProjectsCap)
        }
    }

    /// Per folder: when it was last used and how many removed cards its drawer lists.
    ///
    /// Last used is the latest of three things, because each one alone misses projects: the record
    /// (opened / put away), the activity of the cards on the board now, and that of its removed
    /// cards. The archive is also what dates a project closed before the record existed — its
    /// removed cards still say where and when — so the menu is not empty on the first launch. Rows
    /// from before `lastActivity` was archived fall back to when they were removed.
    ///
    /// The count follows `archived(inProject:)` row for row: transcript only, one per conversation,
    /// matched by path and by id only for rows that predate the path. Here it is by path for every
    /// folder at once, which a closed project — whose id is gone — needs.
    func projectUsage() -> [String: ProjectUsage] {
        var out: [String: ProjectUsage] = [:]
        func bump(_ path: String, _ d: Date) {
            let cur = out[path]?.lastUsed
            out[path, default: ProjectUsage()].lastUsed = max(cur ?? d, d)
        }
        for r in recentProjects { bump(r.path, r.lastUsed) }
        let pathOf = Dictionary(projects.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        for t in terminals {
            if let a = t.lastActivity, let path = pathOf[t.projectId] { bump(path, a) }
        }
        var seen: [String: Set<String>] = [:]
        for row in terminalArchive {
            guard let transcript = row.transcriptPath else { continue }
            let own = row.projectPath.flatMap { $0.isEmpty ? nil : $0 }
            guard let path = own ?? pathOf[row.projectId] else { continue }
            bump(path, row.lastActivity ?? row.removedAt)
            if seen[path, default: []].insert(transcript).inserted { out[path, default: ProjectUsage()].history += 1 }
        }
        return out
    }

    /// Every project the board has had, most recently used first. One still on the board is
    /// always listed; one off it only while its folder still exists — a folder that was moved or
    /// deleted has nothing to open.
    func recentProjectRows() -> [RecentProjectRow] {
        let usage = projectUsage()
        let onBoard = Dictionary(projects.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let remembered = Dictionary(recentProjects.map { ($0.path, $0.name) }, uniquingKeysWith: { a, _ in a })
        let fm = FileManager.default
        var rows: [RecentProjectRow] = []
        for path in Set(usage.keys).union(onBoard.keys) {
            let p = onBoard[path]
            if p == nil {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            }
            rows.append(RecentProjectRow(
                path: path,
                name: p?.name ?? remembered[path] ?? URL(fileURLWithPath: path).lastPathComponent,
                lastUsed: usage[path]?.lastUsed, history: usage[path]?.history ?? 0,
                projectId: p?.id))
        }
        return rows.sorted { a, b in
            switch (a.lastUsed, b.lastUsed) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}
