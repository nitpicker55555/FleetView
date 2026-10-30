import AppKit
import FleetViewFiles
import SwiftUI

/// Run `work` on a utility queue and come back with its result.
func onUtility<T>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in
        DispatchQueue.global(qos: .utility).async { c.resume(returning: work()) }
    }
}

/// A repository the window shows: the project's own, or one inside a project folder that is not a
/// repository itself.
struct RepoRef: Equatable {
    let repo: GitReader.Repo
    /// "" for the project's own repository; otherwise the folder, relative to the project root, that
    /// is the repository's top level — or, for a repository outside the project, its absolute path.
    let folder: String

    /// A repository outside the project that one of its cards committed to (FileBrowserModel+Commits).
    /// Only the 提交 page shows it: nothing in the tree is in it, and nothing here watches it.
    var isExternal: Bool { folder.hasPrefix("/") }
    /// The project root's path inside the repository: "" unless the project is a folder inside it.
    let rootInRepo: String

    /// A repository-relative path as the tree names it, or nil when it is outside the project.
    func project(_ p: String) -> String? {
        if isExternal { return nil }
        if !folder.isEmpty { return p.isEmpty ? folder : folder + "/" + p }
        if rootInRepo.isEmpty { return p }
        if p == rootInRepo { return "" }
        return p.hasPrefix(rootInRepo + "/") ? String(p.dropFirst(rootInRepo.count + 1)) : nil
    }

    /// A path in the tree as the repository names it.
    func inRepo(_ rel: String) -> String {
        if isExternal { return rel }
        if !folder.isEmpty { return rel == folder ? "" : String(rel.dropFirst(folder.count + 1)) }
        if rootInRepo.isEmpty { return rel }
        return rel.isEmpty ? rootInRepo : rootInRepo + "/" + rel
    }

    /// Whether a path in the tree is in this repository.
    func contains(_ rel: String) -> Bool {
        !isExternal && (folder.isEmpty || rel == folder || rel.hasPrefix(folder + "/"))
    }

    /// The part of the repository the window shows: the project's folder in it, or all of it.
    var scope: String? { rootInRepo.isEmpty ? nil : rootInRepo }
}

/// The status bar's cursor and diff counts (see `FileBrowserModel.statusBar`).
@MainActor
final class FileStatusModel: ObservableObject {
    @Published var status = FileBrowserModel.Status()
}

/// Everything one file window knows: the tree, the tabs, what git says, what is unsaved.
///
/// Its own object rather than part of AppState on purpose: AppState publishes to the whole board,
/// and a keystroke in an editor must never make the board lay itself out again.
@MainActor
final class FileBrowserModel: ObservableObject, EditorHost {
    struct Row: Identifiable, Equatable {
        let id: String          // path relative to the project root
        let name: String
        let depth: Int
        let isDir: Bool
        let ignored: Bool
    }

    enum Kind: Equatable { case text, image, other, changes }
    enum Mode: String { case source, preview }

    struct Tab: Identifiable, Equatable {
        let id: String
        var path: String        // relative to the project root
        var pinned: Bool
        var kind: Kind
        var mode: Mode
        var dirty = false
        var readOnly: String? = nil
        var wrap = false
        /// For a `.changes` tab: which changes it shows.
        var changes: ChangeSpec? = nil
    }

    enum Banner: Equatable {
        /// The file changed on disk while there are unsaved edits (or a save found it changed).
        case diskChanged
        case deleted
        case failed(String)
        /// Unsaved edits from an earlier session; `sameBase` when they were made against this version.
        case recovered(Date, sameBase: Bool)
        /// The editor page crashed and came back; unsaved edits were restored.
        case crashRestored
    }

    struct Status: Equatable {
        var line = 0, col = 0, lines = 0
        var added = 0, changed = 0, deleted = 0
        var noHead = false
        var hasDiff = false
    }

    /// What Swift keeps about an open text file: what the page was given, and how to put it back.
    struct Doc {
        var abs: String
        var lang: String
        var base: String?
        var eol: FileText.EOL = .lf
        var bom = false
        var fingerprint: FileSave.Fingerprint?
        var size: Int64 = 0
        /// Changed on disk while the tab was out of sight: looked at again when shown.
        var stale = false
        var recoveryOffered = false
        /// The version on disk the "changed on disk" banner is about: what Overwrite replaces, and
        /// nothing newer.
        var diskSeen: String?
    }

    /// A read through `disk/`: becomes the tab's version only when the page says it applied it.
    struct DiskRead {
        let version: String
        let eol: FileText.EOL
        let bom: Bool
        let fingerprint: FileSave.Fingerprint?
        let size: Int64
        let readOnly: String?
    }

    struct Entry { let name: String; let isDir: Bool }

    let projectId: UUID
    let projectName: String
    let root: String
    weak var app: AppState?
    weak var window: NSWindow?
    let editor = EditorBridge()

    @Published private(set) var repo: GitReader.Repo?
    @Published private(set) var branch: String?
    /// Repositories inside a project folder that is not one (see RepoRef). Empty when `repo` is set.
    @Published private(set) var nested: [RepoRef] = []
    /// Their branches, by folder.
    @Published private(set) var nestedBranches: [String: String] = [:]
    @Published private(set) var rows: [Row] = []
    @Published private(set) var marks: [String: GitStatus.Mark] = [:]
    @Published private(set) var dirtyDirs: Set<String> = []
    @Published var showIgnored = false { didSet { if showIgnored != oldValue { rebuildRows() } } }
    @Published var tabs: [Tab] = []
    @Published var activeTab: String?
    @Published private(set) var banners: [String: Banner] = [:]
    /// Cursor and diff counts, which change with every keystroke: their own object, so typing redraws
    /// the status bar and not the tree, the tabs and the toolbar.
    let statusBar = FileStatusModel()
    var status: Status {
        get { statusBar.status }
        set { if statusBar.status != newValue { statusBar.status = newValue } }
    }
    @Published var revealTarget: String?
    /// The row last clicked in the tree, file or folder — what ⌥⌘C copies when the tree has focus.
    /// Follows the tab in front when a tab is shown.
    @Published var selected: String?
    @Published var toast: String?

    // Finding files (FileBrowserModel+Find).
    enum SideMode: Hashable { case tree, search, history }
    /// The sidebar put away (its button, ⌃⌘S, or dragged shut), leaving the window to the tabs.
    @Published var sidebarHidden = false
    @Published var sideMode: SideMode = .tree { didSet { if sideMode == .history && oldValue != .history { historyShown() } } }
    @Published var filter = "" { didSet { if filter != oldValue { runFilter() } } }
    @Published var filterResults: [String] = []
    @Published var quickOpen = false {
        // Back to the text it was opened over (or the file it opened), not left on nothing.
        didSet { if oldValue && !quickOpen { focusEditor() } }
    }
    @Published var quickQuery = "" { didSet { if quickQuery != oldValue { runQuickOpen() } } }
    @Published var quickResults: [FuzzyMatch.Match] = []
    @Published var quickSelection = 0
    @Published var searchQuery = ""
    @Published var searchCaseSensitive = false
    @Published var searchResults: [SearchGroup] = []
    @Published var searchState: SearchState = .idle
    @Published var canGoBack = false
    @Published var canGoForward = false
    var fileIndex: [String]?
    /// Untracked files small enough to search (relative to the project root).
    var untrackedFiles: [String]?
    var fileIndexAt = Date.distantPast
    var fileIndexStale = true
    var fileIndexLoading = false
    var fileIndexWaiters: [([String]) -> Void] = []
    var findGeneration = 0
    var searchCancel: CancelToken?
    var backStack: [String] = []
    var forwardStack: [String] = []
    var navigating = false
    var recentOpened: [String] = []

    // History (FileBrowserModel+History).
    /// The repository the 提交 page shows, by folder ("" is the project's own).
    @Published var historyRepo = ""
    /// The branch it lists; nil is HEAD.
    @Published var historyRef: String?
    /// A file or folder whose history it lists (project-relative); nil for all of it.
    @Published var historyPath: String?
    @Published var commits: [GitCommit] = []
    @Published var historyState: HistoryState = .idle
    // Who committed (FileBrowserModel+Commits).
    /// The card that made each listed commit, by sha.
    @Published var commitAuthors: [String: CommitAuthor] = [:]
    /// A card whose commits the page lists, across every repository, instead of one repository's.
    @Published var historyCard: CommitAuthor?
    @Published var cardCommits: [CardCommit] = []
    /// What that card has written and nobody has committed yet, by repository.
    @Published var cardUncommitted: [CardUncommitted] = []
    @Published var cardCommitsLoading = false
    /// Repositories outside the project that its cards have committed to.
    @Published var externalRepos: [RepoRef] = []
    /// This project's cards that have committed anything, for the page's card menu.
    @Published var committers: [CommitAuthor] = []
    var authorsGeneration = 0
    @Published var branchList: [GitBranch] = []
    /// A commit picked as one end of a comparison, waiting for the other.
    @Published var comparePick: String?
    var historyStale = true
    var historyGeneration = 0
    /// What a changes tab's page asked for, by tab: the files, to answer `patch/` and `blob/` by index.
    var changeFiles: [String: [ChangeFile]] = [:]

    // Recently changed files (FileBrowserModel+Recent).
    struct Recent: Identifiable, Equatable {
        let path: String        // relative to the project root
        let at: Date
        let by: String?         // the card whose agent wrote it, when its hook said so
        var id: String { path }
    }
    @Published var recent: [Recent] = []
    let openedAt = Date()
    var observedChanges: [String: Date] = [:]
    var recentTimer: DispatchWorkItem?
    var recentBuiltAt = Date.distantPast
    var observeTimer: DispatchWorkItem?
    var observePending: Set<String> = []
    var observedAt = Date.distantPast
    var editsObserver: NSObjectProtocol?

    private var listings: [String: [Entry]] = [:]
    private var ignoredNames: [String: Set<String>] = [:]
    /// The local .gitignore's modification time each listing's ignore marks were taken with.
    private var ignoreStamp: [String: Date] = [:]
    private var loading: Set<String> = []
    private var loadWaiters: [String: [() -> Void]] = [:]
    private var loadedAt: [String: Date] = [:]
    private var diskReads: [String: DiskRead] = [:]
    private var saveTasks: [String: Task<[String: Any], Never>] = [:]
    private(set) var expanded: Set<String> = [""]
    private var docs: [String: Doc] = [:]
    private var watches: [String: FileWatch] = [:]
    private var checks: [String: DispatchWorkItem] = [:]
    private var watcher: ProjectWatcher?
    /// The project's path inside its repository ("" when the project is the repository).
    private(set) var rootInRepo = ""
    private(set) var untrackedDirs: Set<String> = []
    /// Staged renames: new path → the path HEAD has it under.
    private(set) var renames: [String: String] = [:]
    private(set) var headCommit: String?
    /// Per repository (by folder), what HEAD was the last time it was looked at.
    private var headCommits: [String: String] = [:]
    private var headSignatures: [String: String] = [:]
    /// Each repository's last status, by folder; merged into `marks` and the rest.
    private var statusBy: [String: RepoStatus] = [:]
    func repoStatus(_ folder: String) -> RepoStatus? { statusBy[folder] }
    struct RepoStatus {
        var marks: [String: GitStatus.Mark] = [:]
        var untracked: Set<String> = []
        var renames: [String: String] = [:]
    }
    private var toastTimer: DispatchWorkItem?
    private var lastKey: (name: String, from: KeySource, at: Date) = ("", .window, .distantPast)

    /// The window can be seen. Everything that costs anything waits for this.
    var visible = true {
        didSet {
            guard visible && !oldValue else { return }
            flushPending()
            if gitStale { requestStatus(after: 0.2) }
            if let a = activeTab, docs[a]?.stale == true { docs[a]?.stale = false; Task { await check(a) } }
        }
    }
    var isKey = false { didSet { if isKey && !oldValue { checkHead(); requestStatus(after: 0.2) } } }

    init(project: Project, app: AppState) {
        projectId = project.id
        projectName = project.name
        root = URL(fileURLWithPath: (project.path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        self.app = app
        editor.host = self
    }

    // MARK: - Paths

    func absolute(_ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }

    /// `abs` relative to the project root, or nil when it is outside it. Taken apart first: a path
    /// like `root/../elsewhere` starts with the root and is not in it.
    func relative(_ abs: String) -> String? {
        let std = URL(fileURLWithPath: (abs as NSString).expandingTildeInPath).standardizedFileURL.path
        let real = URL(fileURLWithPath: std).resolvingSymlinksInPath().path
        for candidate in [std, real] {
            if candidate == root { return "" }
            if candidate.hasPrefix(root + "/") { return String(candidate.dropFirst(root.count + 1)) }
        }
        return nil
    }

    private static func parent(_ rel: String) -> String {
        guard let i = rel.lastIndex(of: "/") else { return "" }
        return String(rel[..<i])
    }

    // MARK: - Lifecycle

    func start() {
        load("")
        Task {
            let root = self.root
            let repo = await onUtility { GitReader.shared.repo(at: root) }
            self.repo = repo
            if let repo {
                let top = URL(fileURLWithPath: repo.toplevel).resolvingSymlinksInPath().path
                rootInRepo = root == top ? "" : (root.hasPrefix(top + "/") ? String(root.dropFirst(top.count + 1)) : "")
                for dir in listings.keys { load(dir) }      // now with .gitignore applied
                readBranch()
                checkHead()
                requestStatus(after: 0)
            } else {
                await self.discoverNested()
            }
            startWatching()
            refreshRecent()
        }
        editsObserver = NotificationCenter.default.addObserver(forName: .fileEditsNoted, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let paths = n.object as? [String],
                      paths.contains(where: { $0.hasPrefix(self.root + "/") }) else { return }
                self.refreshRecent(after: 1.5)          // the write lands a moment after the hook
            }
        }
    }

    func stop() {
        if let o = editsObserver { NotificationCenter.default.removeObserver(o) }
        recentTimer?.cancel()
        observeTimer?.cancel()
        flushTimer?.cancel()
        searchCancel?.cancel()
        findGeneration += 1
        watcher?.stop()
        watcher = nil
        for w in watches.values { w.cancel() }
        watches.removeAll()
        checks.values.forEach { $0.cancel() }
        statusTimer?.cancel()
        statusCancel?.cancel()
        editor.tearDown()
    }

    private func startWatching() {
        var gitDirs: [String] = []
        if let repo { gitDirs = [repo.gitDir, repo.commonDir] }
        let w = ProjectWatcher(root: root, gitDirs: gitDirs) { [weak self] batch in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(batch) } }
        }
        w.start()
        watcher = w
    }

    // MARK: - Tree

    private nonisolated static func list(_ abs: String) -> [Entry] {
        let fm = FileManager.default
        // One bulk read of the directory with the type of each entry, not a stat per name; only a
        // link is followed, to show a link to a folder as a folder.
        guard let urls = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: abs, isDirectory: true),
                                                     includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        var dirs: [Entry] = [], files: [Entry] = []
        for url in urls {
            let name = url.lastPathComponent
            guard name != ".git" && name != ".DS_Store" else { continue }
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var isDir = v?.isDirectory ?? false
            if v?.isSymbolicLink == true {
                var d: ObjCBool = false
                isDir = fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
            }
            if isDir { dirs.append(Entry(name: name, isDir: true)) } else { files.append(Entry(name: name, isDir: false)) }
        }
        let order: (Entry, Entry) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // The web's cap: a listing is a screenful of names, and node_modules is not a screenful.
        return Array((dirs.sorted(by: order) + files.sorted(by: order)).prefix(3000))
    }

    /// Read one directory (again). `force`: ask git about ignored names even if they look the same.
    func load(_ dir: String, force: Bool = false, then: (() -> Void)? = nil) {
        if let then { loadWaiters[dir, default: []].append(then) }
        guard !loading.contains(dir) else { return }
        loading.insert(dir)
        let abs = absolute(dir), repo = self.repo
        let prefix = rootInRepo.isEmpty ? "" : rootInRepo + "/"
        // The same names as last time and the same local .gitignore: the ignore marks still hold, and
        // `git check-ignore` is not run again for a folder an agent is only writing into.
        let known = force ? nil : listings[dir].map { list in (Set(list.map(\.name)), ignoredNames[dir] ?? [], ignoreStamp[dir]) }
        Task {
            let lookForGit = repo == nil && !dir.isEmpty && !self.nested.contains { $0.folder == dir }
            let (entries, ignored, stamp) = await onUtility { () -> ([Entry], Set<String>, Date?) in
                let entries = Self.list(abs)
                let stamp = (try? FileManager.default.attributesOfItem(atPath: abs + "/.gitignore"))?[.modificationDate] as? Date
                guard let repo, !entries.isEmpty else { return (entries, [], stamp) }
                if let known, known.0 == Set(entries.map(\.name)), known.2 == stamp { return (entries, known.1, stamp) }
                let base = prefix + (dir.isEmpty ? "" : dir + "/")
                let hits = GitReader.shared.ignored(entries.map { base + $0.name }, in: repo)
                return (entries, Set(hits.map { ($0 as NSString).lastPathComponent }), stamp)
            }
            self.loading.remove(dir)
            self.loadedAt[dir] = Date()
            self.listings[dir] = entries
            self.ignoredNames[dir] = ignored
            self.ignoreStamp[dir] = stamp
            if lookForGit && FileManager.default.fileExists(atPath: abs + "/.git") { self.addNested([dir]) }
            self.rebuildRows()
            let waiting = self.loadWaiters.removeValue(forKey: dir) ?? []
            waiting.forEach { $0() }
        }
    }

    /// Whether a folder's listing is on screen: it and every folder above it are open.
    private func isShown(_ dir: String) -> Bool {
        var d = dir
        while !d.isEmpty {
            if !expanded.contains(d) { return false }
            d = Self.parent(d)
        }
        return true
    }

    private func rebuildRows() {
        var out: [Row] = []
        var missing: [String] = []
        func walk(_ dir: String, _ depth: Int) {
            // An open folder whose listing was dropped while it was out of sight: read it again.
            guard let list = listings[dir] else { missing.append(dir); return }
            let ignored = ignoredNames[dir] ?? []
            for e in list {
                let rel = dir.isEmpty ? e.name : dir + "/" + e.name
                let isIgnored = ignored.contains(e.name)
                if isIgnored && !showIgnored { continue }
                out.append(Row(id: rel, name: e.name, depth: depth, isDir: e.isDir, ignored: isIgnored))
                if e.isDir && expanded.contains(rel) { walk(rel, depth + 1) }
            }
        }
        walk("", 0)
        if out != rows { rows = out }
        for d in missing { load(d) }
    }

    func toggle(_ dir: String) {
        if selected != dir { selected = dir }
        if expanded.contains(dir) {
            expanded.remove(dir)
            rebuildRows()
        } else {
            expand(dir)
        }
    }

    func expand(_ dir: String) {
        expanded.insert(dir)
        if listings[dir] == nil { load(dir) } else { rebuildRows() }
    }

    /// Open every folder above `rel` and scroll it into view.
    func reveal(_ rel: String) {
        var chain: [String] = []
        var d = Self.parent(rel)
        while !d.isEmpty { chain.insert(d, at: 0); d = Self.parent(d) }
        func step(_ i: Int) {
            guard i < chain.count else { rebuildRows(); revealTarget = rel.hasSuffix("/") ? String(rel.dropLast()) : rel; return }
            expanded.insert(chain[i])
            if listings[chain[i]] == nil { load(chain[i]) { step(i + 1) } } else { step(i + 1) }
        }
        step(0)
    }

    /// The card's working directory, opened in the tree.
    func revealDirectory(_ abs: String) {
        guard let rel = relative(abs), !rel.isEmpty else { return }
        sidebarHidden = false
        reveal(rel + "/")
        expand(rel)
        revealTarget = rel
    }

    // MARK: - Watching

    private var pendingDirs: Set<String> = []
    private var pendingIndex = false, pendingHead = false, pendingRescan = false
    private var pendingNested: [String: ProjectWatcher.GitMove] = [:]
    private var flushTimer: DispatchWorkItem?

    private func received(_ b: ProjectWatcher.Batch) {
        pendingDirs.formUnion(b.dirs)
        pendingIndex = pendingIndex || b.index
        pendingHead = pendingHead || b.head
        pendingRescan = pendingRescan || b.rescan
        for (folder, m) in b.nested {
            var e = pendingNested[folder] ?? ProjectWatcher.GitMove()
            e.index = e.index || m.index
            e.head = e.head || m.head
            pendingNested[folder] = e
        }
        // A build running for an hour behind a covered window would otherwise pile up every folder it
        // touched: past a point, looking at everything once is cheaper than remembering each.
        if pendingDirs.count > 2000 { pendingDirs.removeAll(); pendingRescan = true }
        guard visible else { return }          // remembered; looked at when the window shows again
        flushTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.flushPending() }
        flushTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: t)
    }

    private func flushPending() {
        flushTimer?.cancel()
        let touched = pendingRescan ? Set(listings.keys) : pendingDirs.intersection(listings.keys)
        // Folders on screen are read again — each at most once a second, however often it changes.
        // A listing nobody can see is dropped instead, and read when its folder is opened.
        var later: Set<String> = []
        for d in touched {
            if !isShown(d) {
                listings.removeValue(forKey: d); ignoredNames.removeValue(forKey: d); ignoreStamp.removeValue(forKey: d)
            } else if let at = loadedAt[d], Date().timeIntervalSince(at) < 1, !pendingRescan {
                later.insert(d)
            } else {
                load(d, force: pendingRescan)
            }
        }
        if pendingRescan { for id in watches.keys { scheduleCheck(id, after: 0.1) } }
        let nestedMoved = pendingNested
        pendingNested.removeAll()
        if repo == nil {
            let unknown = nestedMoved.keys.filter { f in !nested.contains { $0.folder == f } }
            if !unknown.isEmpty { addNested(unknown) }
        }
        if pendingHead || nestedMoved.values.contains(where: \.head) { checkHead(); readBranch() }
        // An agent writing into a folder git already lists as one untracked entry, or into one it
        // ignores, changes nothing git would report: no status for that.
        let worthStatus = pendingIndex || pendingHead || pendingRescan || !nestedMoved.isEmpty
            || pendingDirs.contains { d in !untrackedDirs.contains { d == $0 || d.hasPrefix($0 + "/") } && !isIgnored(d) }
        if worthStatus { requestStatus() }
        if pendingIndex || pendingRescan || pendingDirs.contains(where: { !isIgnored($0) }) { fileIndexStale = true }
        let observed = pendingDirs.filter { !isIgnored($0) }
        if !observed.isEmpty { observe(observed) }
        pendingDirs = later
        pendingIndex = false; pendingHead = false; pendingRescan = false
        if !later.isEmpty {
            let t = DispatchWorkItem { [weak self] in self?.flushPending() }
            flushTimer = t
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: t)
        }
    }

    /// Whether a folder is, or is inside, one the tree knows .gitignore excludes.
    private func isIgnored(_ dir: String) -> Bool {
        var d = dir
        while !d.isEmpty {
            let parent = Self.parent(d)
            if ignoredNames[parent]?.contains((d as NSString).lastPathComponent) == true { return true }
            d = parent
        }
        return false
    }

    // MARK: - Git status

    private var statusTimer: DispatchWorkItem?
    private var statusRunning = false, statusAgain = false
    private var lastStatusAt = Date.distantPast
    private var lastStatusTook: TimeInterval = 0
    private var statusCancel: CancelToken?
    private var gitStale = false

    /// Ask for a `git status`, at most this often: every 3 s while the window is in front, every 10 s
    /// behind another window, never while it cannot be seen — and never sooner than five times what
    /// the last one took, so a slow repository is asked less often.
    func requestStatus(after delay: TimeInterval = 1.5) {
        guard !repos.isEmpty else { return }
        guard visible else { gitStale = true; return }
        statusTimer?.cancel()
        let minGap = max(isKey ? 3 : 10, lastStatusTook * 5)
        let wait = max(delay, lastStatusAt.addingTimeInterval(minGap).timeIntervalSinceNow)
        let t = DispatchWorkItem { [weak self] in self?.runStatus(attempt: 0) }
        statusTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, wait), execute: t)
    }

    private func runStatus(attempt: Int) {
        guard !repos.isEmpty, visible else { gitStale = true; return }
        if statusRunning { statusAgain = true; return }
        // An agent's git command holds an index right now: let it finish first. A repository still
        // locked after ten tries keeps its last status this round.
        let locked = repos.filter { FileManager.default.fileExists(atPath: $0.repo.gitDir + "/index.lock") }
        if !locked.isEmpty, attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runStatus(attempt: attempt + 1) }
            return
        }
        statusRunning = true
        gitStale = false
        let token = CancelToken()
        statusCancel = token
        let started = Date()
        let refs = repos.filter { r in !locked.contains(r) }
        Task {
            // One after another: the two git slots are shared with every other window.
            let results = await onUtility { () -> [(String, [GitStatus.Entry])] in
                refs.compactMap { r in
                    GitReader.shared.status(r.repo, under: r.scope, cancel: token).map { (r.folder, $0) }
                }
            }
            self.statusRunning = false
            self.lastStatusAt = Date()
            self.lastStatusTook = Date().timeIntervalSince(started)
            for (folder, entries) in results {
                guard let r = self.repos.first(where: { $0.folder == folder }) else { continue }
                self.statusBy[folder] = Self.digest(entries, in: r)
            }
            self.mergeStatus()
            if self.statusAgain { self.statusAgain = false; self.requestStatus() }
        }
    }

    private static func digest(_ entries: [GitStatus.Entry], in r: RepoRef) -> RepoStatus {
        var out = RepoStatus()
        for e in entries {
            var p = e.path
            let isDir = p.hasSuffix("/")
            if isDir { p.removeLast() }
            guard let rel = r.project(p), !rel.isEmpty else { continue }
            out.marks[rel] = e.mark
            if isDir { out.untracked.insert(rel) }
            if let o = e.originalPath, let relO = r.project(o) { out.renames[rel] = relO }
        }
        return out
    }

    private func mergeStatus() {
        statusBy = statusBy.filter { k, _ in repos.contains { $0.folder == k } }
        var m: [String: GitStatus.Mark] = [:], dirs = Set<String>(), untracked = Set<String>(), moved: [String: String] = [:]
        for st in statusBy.values {
            m.merge(st.marks) { a, _ in a }
            untracked.formUnion(st.untracked)
            moved.merge(st.renames) { a, _ in a }
        }
        for rel in m.keys {
            var d = Self.parent(rel)
            while !d.isEmpty { dirs.insert(d); d = Self.parent(d) }
        }
        if m != marks { marks = m }
        if dirs != dirtyDirs { dirtyDirs = dirs }
        untrackedDirs = untracked
        renames = moved
        refreshRecent()
    }

    // MARK: - Repositories

    /// The project's own repository, as a RepoRef.
    var mainRef: RepoRef? { repo.map { RepoRef(repo: $0, folder: "", rootInRepo: rootInRepo) } }

    /// Every repository the window shows: the project's own, or those found inside it.
    var repos: [RepoRef] { mainRef.map { [$0] } ?? nested }

    /// The repository a path in the tree belongs to.
    func repoFor(_ rel: String) -> RepoRef? {
        if let m = mainRef { return m }
        return nested.filter { $0.contains(rel) }.max { $0.folder.count < $1.folder.count }
    }

    func repo(folder: String) -> RepoRef? { (repos + externalRepos).first { $0.folder == folder } }

    /// A project folder that is not a repository may hold some: look three levels down, briefly,
    /// past the folders nobody keeps repositories in. More turn up as the tree lists folders.
    private func discoverNested() async {
        let root = self.root
        let found = await onUtility { () -> [String] in
            let fm = FileManager.default
            let deadline = Date().addingTimeInterval(0.5)
            var out: [String] = [], queue: [(String, Int)] = [("", 0)], seen = 0
            while !queue.isEmpty, seen < 3000, Date() < deadline, out.count < 12 {
                let (rel, depth) = queue.removeFirst()
                seen += 1
                let abs = rel.isEmpty ? root : root + "/" + rel
                if !rel.isEmpty && fm.fileExists(atPath: abs + "/.git") { out.append(rel); continue }
                guard depth < 3, let names = try? fm.contentsOfDirectory(atPath: abs) else { continue }
                for n in names.sorted() where !n.hasPrefix(".") && !ProjectFiles.skipped.contains(n) {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: abs + "/" + n, isDirectory: &isDir), isDir.boolValue {
                        queue.append((rel.isEmpty ? n : rel + "/" + n, depth + 1))
                    }
                }
            }
            return out
        }
        if !found.isEmpty { addNested(found) }
    }

    /// Take these folders on as repositories, if git agrees they are the top of one.
    func addNested(_ folders: [String]) {
        guard repo == nil else { return }
        let root = self.root
        let fresh = folders.filter { f in !nested.contains { $0.folder == f } }
        guard !fresh.isEmpty, nested.count < 12 else { return }
        Task {
            let refs = await onUtility { () -> [RepoRef] in
                fresh.compactMap { f in
                    let abs = root + "/" + f
                    guard let r = GitReader.shared.repo(at: abs),
                          URL(fileURLWithPath: r.toplevel).resolvingSymlinksInPath().path == abs else { return nil }
                    return RepoRef(repo: r, folder: f, rootInRepo: "")
                }
            }
            let added = refs.filter { r in !self.nested.contains { $0.folder == r.folder } }
            guard !added.isEmpty else { return }
            self.nested = (self.nested + added).sorted { $0.folder < $1.folder }.prefix(12).map { $0 }
            self.readBranch()
            self.checkHead()
            self.requestStatus(after: 0)
            self.historyReposChanged()
        }
    }

    private nonisolated static func headSignature(_ repo: GitReader.Repo) -> String? {
        guard let head = try? String(contentsOfFile: repo.gitDir + "/HEAD", encoding: .utf8) else { return nil }
        let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard h.hasPrefix("ref: ") else { return h }
        let ref = String(h.dropFirst(5))
        for dir in [repo.gitDir, repo.commonDir] {
            if let v = try? String(contentsOfFile: dir + "/" + ref, encoding: .utf8) { return h + " " + v }
        }
        // A packed ref: its file says when it changed.
        let packed = (try? FileManager.default.attributesOfItem(atPath: repo.commonDir + "/packed-refs"))?[.modificationDate] as? Date
        return h + " packed " + String(packed?.timeIntervalSince1970 ?? 0)
    }

    /// What HEAD points at, read from the file rather than by running git.
    nonisolated static func branchName(_ repo: GitReader.Repo) -> String? {
        guard let head = try? String(contentsOfFile: repo.gitDir + "/HEAD", encoding: .utf8) else { return nil }
        let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.hasPrefix("ref: refs/heads/") ? String(h.dropFirst("ref: refs/heads/".count)) : String(h.prefix(8))
    }

    private func readBranch() {
        if let repo {
            let b = Self.branchName(repo)
            if b != branch { branch = b }
            window?.subtitle = subtitle
        }
        var nb: [String: String] = [:]
        for r in nested { nb[r.folder] = Self.branchName(r.repo) }
        if nb != nestedBranches { nestedBranches = nb }
    }

    var subtitle: String {
        let path = (root as NSString).abbreviatingWithTildeInPath
        return branch.map { "\(path) · ⎇ \($0)" } ?? path
    }

    /// HEAD moved (a commit, a checkout): every open file's baseline may have changed.
    ///
    /// HEAD and the ref it names are read as files first — two tiny reads — and git is asked only
    /// when they differ from last time. Every focus change and every ref event would otherwise be a
    /// `git rev-parse`.
    func checkHead() {
        for r in repos {
            Task {
                let sig = await onUtility { Self.headSignature(r.repo) }
                if let sig, sig == self.headSignatures[r.folder] { return }
                let commit = await onUtility { GitReader.shared.headCommit(r.repo) }
                self.headSignatures[r.folder] = sig
                self.historyMoved(r.folder)
                guard commit != self.headCommits[r.folder] else { return }
                let first = self.headCommits[r.folder] == nil
                self.headCommits[r.folder] = commit
                if r.folder.isEmpty { self.headCommit = commit }
                guard !first else { return }
                for t in self.tabs where t.kind == .text && r.contains(t.path) { self.editor.call("headChanged", [t.id]) }
            }
        }
    }

    // MARK: - Tabs

    var active: Tab? { tabs.first { $0.id == activeTab } }

    func docLang(_ id: String) -> String { docs[id]?.lang ?? "plain" }
    func docSize(_ id: String) -> Int64? { docs[id]?.size }
    func docEOL(_ id: String) -> String? {
        guard let d = docs[id], d.base != nil else { return nil }
        return (d.eol == .crlf ? "CRLF" : "LF") + (d.bom ? " · BOM" : "")
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "ico", "svg"]
    static let otherExtensions: Set<String> = ["pdf", "zip", "gz", "tgz", "xz", "bz2", "7z", "rar", "dmg", "pkg", "app",
                                               "mp3", "mp4", "mov", "m4a", "wav", "aiff", "sqlite", "db", "jar",
                                               "class", "o", "a", "dylib", "so", "pyc", "woff", "woff2", "ttf", "otf"]

    /// `sniff`: read the first line of a file with no extension for a `#!` — not for a list of
    /// paths from a commit, which may not exist on disk.
    static func language(for path: String, sniff: Bool = true) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "md", "markdown", "mdx": return "markdown"
        case "swift": return "swift"
        case "py", "pyi", "pyw": return "python"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "jsx"
        case "ts", "mts", "cts": return "typescript"
        case "tsx": return "tsx"
        case "json", "jsonc", "jsonl", "resolved", "ipynb", "webmanifest": return "json"
        case "html", "htm", "xhtml": return "html"
        case "xml", "plist", "svg", "xcscheme", "storyboard", "xib", "iml", "entitlements": return "xml"
        case "css", "scss", "less": return "css"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "sh", "bash", "zsh", "fish", "command": return "shell"
        case "rs": return "rust"
        case "go": return "go"
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm": return "cpp"
        case "java", "kt", "kts", "scala", "groovy", "gradle": return "java"
        case "sql": return "sql"
        case "rb": return "ruby"
        case "lua": return "lua"
        case "diff", "patch": return "diff"
        case "ini", "cfg", "conf", "properties", "env": return "properties"
        default: break
        }
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return "dockerfile" }
        if [".gitignore", ".gitattributes", ".dockerignore", ".npmrc", ".editorconfig", ".env"].contains(name)
            || name.hasPrefix(".env.") { return "properties" }
        if [".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile"].contains(name) { return "shell" }
        if name == "makefile" || name == "gnumakefile" { return "shell" }
        // No extension: the first line may say (`scripts/project-manager` is Python).
        if sniff, ext.isEmpty, let h = FileHandle(forReadingAtPath: path) {
            let first = String(decoding: h.readData(ofLength: 120), as: UTF8.self)
            try? h.close()
            if first.hasPrefix("#!") {
                if first.contains("python") { return "python" }
                if first.contains("node") { return "javascript" }
                if first.contains("sh") { return "shell" }
                if first.contains("ruby") { return "ruby" }
            }
        }
        return "plain"
    }

    /// What is at a path, following links: a regular file's size, or why it is not one.
    nonisolated static func kindOf(_ abs: String) -> (type: mode_t, size: Int64)? {
        var st = stat()
        guard stat(abs, &st) == 0 else { return nil }
        return (st.st_mode & S_IFMT, Int64(st.st_size))
    }

    /// Open a file in a tab — the preview tab unless `pin` — or open a folder in the tree.
    func open(_ rel: String, pin: Bool = false, line: Int? = nil, find: String? = nil, anchor: String? = nil) {
        let abs = absolute(rel)
        guard let k = Self.kindOf(abs) else { showToast(L(.filesMissing)); return }
        if k.type == S_IFDIR { reveal(rel + "/"); expand(rel); revealTarget = rel; return }
        // A FIFO, a socket or a device: reading one blocks or never ends.
        guard k.type == S_IFREG else { showToast(L(.filesNotRegular)); return }
        if let i = tabs.firstIndex(where: { $0.path == rel }) {
            if pin { tabs[i].pinned = true }
            activate(tabs[i].id, line: line, find: find, anchor: anchor)
            return
        }
        let size = k.size
        if size > 100_000_000, !confirmLarge(rel, size: size) { return }

        let ext = (abs as NSString).pathExtension.lowercased()
        let kind: Kind = Self.imageExtensions.contains(ext) ? .image : (Self.otherExtensions.contains(ext) ? .other : .text)
        let lang = Self.language(for: abs)
        let id = UUID().uuidString
        let tab = Tab(id: id, path: rel, pinned: pin, kind: kind, mode: lang == "markdown" ? .preview : .source)
        placeTab(tab, pin: pin)
        docs[id] = Doc(abs: abs, lang: lang, size: size)
        activeTab = id
        status = Status()
        if kind == .text { watch(id) }

        var meta: [String: Any] = ["path": abs, "root": root, "lang": lang, "mode": tab.mode.rawValue, "kind": kind == .text ? "text" : "info"]
        if let line { meta["line"] = line }
        if let find { meta["find"] = find }
        if let anchor { meta["anchor"] = anchor }
        if kind == .image {
            meta["info"] = ["kind": "image", "url": Self.rawURL(abs), "detail": Self.sizeText(size)]
        } else if kind == .other {
            meta["info"] = binaryInfo(rel, size: size)
        }
        editor.call("open", [id, meta]) { [weak self] r in
            guard let self, let r = r as? [String: Any] else { return }
            if let reason = r["reason"] as? String, !reason.isEmpty, let i = self.tabs.firstIndex(where: { $0.id == id }) {
                self.tabs[i].readOnly = reason
            }
        }
        noteOpened(rel)
        reveal(rel)
    }

    /// A new tab goes where the preview tab was (unless `pin`), or after the one in front.
    func placeTab(_ tab: Tab, pin: Bool) {
        if !pin, let i = tabs.firstIndex(where: { !$0.pinned && !$0.dirty }) {
            let old = tabs[i].id
            tabs[i] = tab
            dispose(old)
        } else if let a = tabs.firstIndex(where: { $0.id == activeTab }) {
            tabs.insert(tab, at: a + 1)
        } else {
            tabs.append(tab)
        }
    }

    static func rawURL(_ abs: String) -> String {
        "fvfile://app/raw" + abs.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0)
        }.reduce("") { $0 + "/" + $1 }
    }

    static func sizeText(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func binaryInfo(_ rel: String, size: Int64) -> [String: Any] {
        var actions = [["id": "reveal", "label": L(.filesReveal)]]
        if Self.safeToOpen(absolute(rel)) { actions.insert(["id": "openDefault", "label": L(.filesOpenDefault)], at: 0) }
        return ["kind": "binary", "title": (rel as NSString).lastPathComponent,
                "detail": L(.filesBinaryDetail(Self.sizeText(size))), "actions": actions]
    }

    /// Whether "open with the default app" only opens the file. For a program, a script or an app
    /// bundle it runs it — a file an agent just wrote, one click away from executing.
    static func safeToOpen(_ abs: String) -> Bool {
        let ext = (abs as NSString).pathExtension.lowercased()
        let runs: Set<String> = ["app", "command", "tool", "terminal", "workflow", "action", "pkg", "mpkg", "scpt",
                                 "applescript", "scptd", "sh", "zsh", "bash", "csh", "fish", "py", "pyw", "rb", "pl",
                                 "php", "js", "jar", "webloc", "inetloc", "fileloc", "dmg", "prefPane", "kext"]
        if runs.contains(ext) { return false }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: abs, isDirectory: &isDir), isDir.boolValue { return false }
        return !FileManager.default.isExecutableFile(atPath: abs)
    }

    private func confirmLarge(_ rel: String, size: Int64) -> Bool {
        let a = NSAlert()
        a.messageText = L(.filesLargeTitle((rel as NSString).lastPathComponent, Self.sizeText(size)))
        a.informativeText = L(.filesLargeBody)
        a.addButton(withTitle: L(.filesOpen))
        a.addButton(withTitle: L(.cancel))
        return a.runModal() == .alertFirstButtonReturn
    }

    func activate(_ id: String, line: Int? = nil, find: String? = nil, anchor: String? = nil) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTab = id
        status = Status()
        var whereTo: [String: Any] = [:]
        if let line { whereTo["line"] = line }
        if let find { whereTo["find"] = find }
        if let anchor { whereTo["anchor"] = anchor }
        editor.call("show", [id]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Changed while out of sight: looked at now, and before jumping — a reload after the
                // jump would put the scroll back where it was.
                if self.docs[id]?.stale == true {
                    self.docs[id]?.stale = false
                    await self.check(id)
                }
                if !whereTo.isEmpty { self.editor.call("jump", [id, whereTo]) }
            }
        }
        if let t = tabs.first(where: { $0.id == id }), t.kind != .changes { reveal(t.path); noteOpened(t.path) }
    }

    func pin(_ id: String) {
        if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].pinned = true }
    }

    func setMode(_ id: String, _ mode: Mode) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].mode = mode
        editor.call("setMode", [id, mode.rawValue])
    }

    func toggleWrap(_ id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].wrap.toggle()
        editor.call("setWrap", [id, tabs[i].wrap])
    }

    /// Close a tab; unsaved edits are asked about first.
    func close(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        guard tab.dirty else { closeNow(id); return }
        askAboutUnsaved([tab]) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .save: self.saveTabs([tab]) { ok in if ok { self.closeNow(id) } }
            case .discard:
                if let d = self.docs[id] { FileRecovery.remove(path: d.abs, now: true) }
                self.closeNow(id)
            case .cancel: break
            }
        }
    }

    private func closeNow(_ id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        dispose(id)
        if activeTab == id {
            activeTab = nil
            if !tabs.isEmpty { activate(tabs[min(i, tabs.count - 1)].id) }
        }
        updateEdited()
    }

    private func dispose(_ id: String) {
        editor.call("close", [id])
        watches.removeValue(forKey: id)?.cancel()
        checks.removeValue(forKey: id)?.cancel()
        docs.removeValue(forKey: id)
        changeFiles.removeValue(forKey: id)
        diskReads.removeValue(forKey: id)
        banners.removeValue(forKey: id)
    }

    /// ⌘W: the tab in front, or — with none left — the window.
    func closeActive() {
        if let a = activeTab { close(a) } else { window?.performClose(nil) }
    }

    private func updateEdited() {
        window?.isDocumentEdited = tabs.contains { $0.dirty }
    }

    // MARK: - Serving the page

    func serve(_ kind: String, _ rest: String) async -> EditorBridge.Response {
        switch kind {
        case "doc": return await serveDoc(rest, updateBase: true)
        case "disk": return await serveDoc(rest, updateBase: false)
        case "head": return await serveHead(rest)
        case "raw": return await serveRaw(rest)
        case "changes": return await serveChanges(rest)
        case "patch": return await servePatch(rest)
        case "blob": return await serveBlob(rest)
        default: return .notFound
        }
    }

    private struct TextRead: Sendable {
        let body: Data              // the LF-only text, ready to send
        let eol: FileText.EOL
        let bom: Bool
        let version: String
        let fingerprint: FileSave.Fingerprint?
        let size: Int64
        let readOnly: String?
    }

    private enum Read: Sendable {
        case missing
        case notRegular
        case binary(Int64)
        case notUTF8(Int64)
        case text(TextRead)
    }

    /// Everything about a file the page and a save need, read and decoded off the main thread.
    private nonisolated static func read(_ abs: String) -> Read {
        guard let k = kindOf(abs) else { return .missing }
        guard k.type == S_IFREG else { return .notRegular }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: abs), options: .alwaysMapped) else { return .missing }
        let size = Int64(data.count)
        if FileText.isBinary(data) { return .binary(size) }
        guard let d = FileText.decode(data) else { return .notUTF8(size) }
        var reason = d.readOnlyReason?.rawValue
        if reason == nil && access(abs, W_OK) != 0 { reason = FileText.ReadOnly.notWritable.rawValue }
        return .text(TextRead(body: Data(d.text.utf8), eol: d.eol, bom: d.bom, version: FileText.version(data),
                              fingerprint: FileSave.fingerprint(path: abs), size: size, readOnly: reason))
    }

    /// The text of a tab's file, LF-only.
    ///
    /// `doc/` (`updateBase`) is a first read: the page has nothing else for the tab, so this is what it
    /// will hold and what a save is checked against. `disk/` — a reload, "use the disk version",
    /// compare — changes nothing here: the page may still decide not to take it (the user typed
    /// meanwhile), and says `applied` when it did.
    private func serveDoc(_ id: String, updateBase: Bool) async -> EditorBridge.Response {
        guard let doc = docs[id] else { return .notFound }
        let abs = doc.abs
        let r = await onUtility { Self.read(abs) }
        let name = (abs as NSString).lastPathComponent
        switch r {
        case .missing:
            return .json(404, ["kind": "missing", "title": L(.filesMissing), "detail": name])
        case .notRegular:
            return .json(415, ["kind": "binary", "title": name, "detail": L(.filesNotRegular)])
        case .binary(let size):
            return .json(415, binaryInfo(relative(abs) ?? name, size: size))
        case .notUTF8(let size):
            return .json(415, ["kind": "binary", "title": name, "detail": L(.filesNotUTF8(Self.sizeText(size))),
                               "actions": [["id": "openDefault", "label": L(.filesOpenDefault)]]])
        case .text(let t):
            let read = DiskRead(version: t.version, eol: t.eol, bom: t.bom, fingerprint: t.fingerprint,
                                size: t.size, readOnly: t.readOnly)
            if updateBase {
                commit(id, read)
                offerRecovery(id)
            } else {
                diskReads[id] = read
            }
            var headers = ["X-FV-Version": t.version]
            if let reason = t.readOnly { headers["X-FV-ReadOnly"] = reason }
            return EditorBridge.Response(status: 200, mime: "text/plain; charset=utf-8", data: t.body, headers: headers)
        }
    }

    /// The editor holds this version of the file now.
    private func commit(_ id: String, _ r: DiskRead) {
        guard var d = docs[id] else { return }
        d.base = r.version
        d.eol = r.eol
        d.bom = r.bom
        d.fingerprint = r.fingerprint
        d.size = r.size
        d.stale = false
        d.diskSeen = nil
        docs[id] = d
        if let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].readOnly != r.readOnly { tabs[i].readOnly = r.readOnly }
    }

    /// The file as HEAD has it, LF-only like the editor's text, for the tint of changed lines.
    /// 404 — no tint — for a file HEAD does not have (new, untracked, no commits yet) and for files
    /// above 20 MB, where the page does not diff anyway.
    func serveHead(_ id: String) async -> EditorBridge.Response {
        guard let doc = docs[id], let rel0 = relative(doc.abs), repoFor(rel0) != nil, doc.size <= 20_000_000 else { return .notFound }
        var target = doc.abs
        // A rename staged in the index: HEAD has the file under its old name.
        if let rel = relative(doc.abs), let old = renames[rel] { target = absolute(old) }
        let file = target
        let body: Data? = await onUtility {
            guard let blob = GitReader.shared.headBlob(file: file) else { return nil }
            let data: Data
            if let hit = BlobCache.shared.get(blob.oid) { data = hit } else {
                guard let d = GitReader.shared.checkedOut(oid: blob.oid, path: blob.path, near: file) else { return nil }
                BlobCache.shared.put(blob.oid, d)
                data = d
            }
            // Decoded the same way as the working file, so line endings never count as a change.
            return FileText.decode(data).map { Data($0.text.utf8) }
        }
        guard let body else { return .notFound }
        return EditorBridge.Response(status: 200, mime: "text/plain; charset=utf-8", data: body)
    }

    private func serveRaw(_ path: String) async -> EditorBridge.Response {
        // Images in a rendered document, and image tabs: only from inside the project.
        guard relative(path) != nil else { return .notFound }
        let data = await onUtility { () -> Data? in
            guard Self.kindOf(path)?.type == S_IFREG else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        }
        guard let data else { return .notFound }
        let ext = (path as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        case "svg": mime = "image/svg+xml"
        case "bmp": mime = "image/bmp"
        case "tif", "tiff": mime = "image/tiff"
        case "heic": mime = "image/heic"
        case "ico": mime = "image/x-icon"
        default: mime = "application/octet-stream"
        }
        return EditorBridge.Response(status: 200, mime: mime, data: data)
    }

    // MARK: - Messages from the page

    func editorReady() {}

    /// The page came back after its process died: open the tabs again, and put back unsaved text.
    ///
    /// The restored text was written against the version the tab had before the crash, not the one
    /// the page reads now: that older version stays the base, so a save over an agent's write since
    /// then is a conflict and not a silent overwrite.
    func editorCrashed() {
        let open = tabs
        let current = activeTab
        for t in open {
            guard let d = docs[t.id] else { continue }
            let before = d.base
            if let i = tabs.firstIndex(where: { $0.id == t.id }) { tabs[i].dirty = false }   // the page says again
            var meta: [String: Any] = ["path": d.abs, "root": root, "lang": d.lang, "mode": t.mode.rawValue,
                                       "kind": t.kind == .text ? "text" : "info"]
            if t.kind == .image { meta["info"] = ["kind": "image", "url": Self.rawURL(d.abs), "detail": Self.sizeText(d.size)] }
            if t.kind == .other { meta["info"] = binaryInfo(t.path, size: d.size) }
            editor.call("open", [t.id, meta])
            if t.dirty, let entry = FileRecovery.load(path: d.abs) {
                banners[t.id] = .crashRestored
                editor.call("restore", [t.id, entry.text]) { [weak self] ok in
                    if ok as? Bool == true { self?.rebase(t.id, to: before ?? entry.base) }
                }
            }
        }
        updateEdited()
        if let current { editor.call("show", [current]) }
    }

    /// Edits now in the tab were made against `base`: that is what a save is checked against. When
    /// the disk has moved on since, say so now rather than at the save.
    private func rebase(_ id: String, to base: String?) {
        guard let current = docs[id]?.base, base != current else { return }
        docs[id]?.base = base
        docs[id]?.diskSeen = current
        banners[id] = .diskChanged
    }

    func editorMessage(_ type: String, _ body: [String: Any]) async -> Any? {
        let tab = body["tab"] as? String
        switch type {
        case "dirty":
            if let tab, let i = tabs.firstIndex(where: { $0.id == tab }) {
                let dirty = body["dirty"] as? Bool ?? false
                if tabs[i].dirty != dirty { tabs[i].dirty = dirty }
                if dirty && !tabs[i].pinned { tabs[i].pinned = true }   // an edited preview tab must not be replaced
                // Back to what is on disk (saved, or undone): nothing left to recover.
                if !dirty, let d = docs[tab], banners[tab].map({ if case .recovered = $0 { return false }; return true }) ?? true {
                    FileRecovery.remove(path: d.abs)
                }
                updateEdited()
            }
        case "snapshot":
            // A snapshot can arrive after the save that made it moot.
            if let tab, let d = docs[tab], let text = body["text"] as? String, tabs.first(where: { $0.id == tab })?.dirty == true {
                FileRecovery.write(path: d.abs, base: d.base, text: text)
            }
        case "save":
            if let tab, let text = body["text"] as? String { return await save(tab, text: text) }
        case "saveMerged":
            // Against the version the left side showed: if the disk moved again since, that is a
            // conflict too.
            if let tab, let text = body["text"] as? String {
                return await save(tab, text: text, base: .some(body["base"] as? String))
            }
        case "applied":
            if let tab, let v = body["version"] as? String, let r = diskReads[tab], r.version == v {
                diskReads.removeValue(forKey: tab)
                commit(tab, r)
                if let b = banners[tab], b == .diskChanged || b == .deleted { banners.removeValue(forKey: tab) }
            }
        case "reloadSkipped":
            // Typed into while the new version was on its way: the edits stay, and so does the choice.
            if let tab, docs[tab] != nil {
                docs[tab]?.diskSeen = diskReads[tab]?.version
                banners[tab] = .diskChanged
            }
        case "cursor":
            if tab == activeTab {
                var s = status
                s.line = body["line"] as? Int ?? 0
                s.col = body["col"] as? Int ?? 0
                s.lines = body["lines"] as? Int ?? 0
                status = s
            }
        case "diffStats":
            if tab == activeTab {
                var s = status
                s.added = body["added"] as? Int ?? 0
                s.changed = body["changed"] as? Int ?? 0
                s.deleted = body["deleted"] as? Int ?? 0
                s.noHead = body["none"] as? Bool ?? false
                s.hasDiff = true
                status = s
            }
        case "link":
            if let href = body["href"] as? String, let from = body["from"] as? String { followLink(href, from: from) }
        case "key":
            if let name = body["name"] as? String { key(name, from: .page) }
        case "action":
            if let tab, let id = body["id"] as? String, let d = docs[tab] {
                if id == "openDefault", Self.safeToOpen(d.abs) { NSWorkspace.shared.open(URL(fileURLWithPath: d.abs)) }
                if id == "reveal" { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.abs)]) }
            }
        case "openFile":
            if let path = body["path"] as? String { open(path, pin: true, line: body["line"] as? Int) }
        case "openCommit":
            if let sha = body["sha"] as? String, let spec = tabs.first(where: { $0.id == tab })?.changes {
                openCommit(sha, in: spec.repoFolder, pin: true)
            }
        case "compareWorktree":
            if let sha = body["sha"] as? String, let spec = tabs.first(where: { $0.id == tab })?.changes {
                compareWithWorktree(sha, in: spec.repoFolder)
            }
        case "copy":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                showToast(L(.filesCopied))
            }
        case "mode":
            if let tab, let m = (body["mode"] as? String).flatMap(Mode.init(rawValue:)),
               let i = tabs.firstIndex(where: { $0.id == tab }) { tabs[i].mode = m }
        default: break
        }
        return nil
    }

    enum KeySource { case page, window }

    /// A window-level key, from the page or from the window's own shortcuts. Should one press ever
    /// arrive both ways, the second arrival — from the other side, within a moment — is dropped;
    /// two presses from the same side are two presses (⌘W ⌘W closes two tabs).
    func key(_ name: String, from: KeySource = .window) {
        if lastKey.name == name && lastKey.from != from && Date().timeIntervalSince(lastKey.at) < 0.25 { return }
        lastKey = (name, from, Date())
        switch name {
        case "closeTab": closeActive()
        // ⌥⌘C, as in Finder. From the editor it is the file being edited; from the tree, the row
        // last clicked there.
        case "copyPath":
            let rel = from == .page ? active?.path : (selected ?? active?.path)
            if let rel { copyPath(rel) }
        case "save": editor.call("saveActive")
        case "quickOpen": showQuickOpen()
        case "searchFiles": sideMode = .search
        case "back": goBack()
        case "forward": goForward()
        default: break
        }
    }

    private func followLink(_ href: String, from: String) {
        if href.hasPrefix("http://") || href.hasPrefix("https://") || href.hasPrefix("mailto:") {
            if let url = URL(string: href) { NSWorkspace.shared.open(url) }
            return
        }
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let target = (parts.first ?? "").split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !target.isEmpty else { return }
        let decoded = target.removingPercentEncoding ?? target
        let base = (from as NSString).deletingLastPathComponent
        let joined = decoded.hasPrefix("/") ? root + decoded : base + "/" + decoded
        let abs = URL(fileURLWithPath: joined).standardizedFileURL.path
        guard let rel = relative(abs) else { showToast(L(.filesOutside)); return }
        open(rel, pin: true, anchor: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }

    // MARK: - Saving

    /// Save a tab's text, one save per tab at a time: the page's ⌘S, a save from the quit prompt and
    /// a merge can all ask at once, and the second must be checked against what the first wrote.
    /// `base`: the version to check against; the tab's own when not given.
    private func save(_ id: String, text: String, base: String?? = nil, force: Bool = false) async -> [String: Any] {
        let previous = saveTasks[id]
        let task = Task { @MainActor () -> [String: Any] in
            _ = await previous?.value
            return await self.saveNow(id, text: text, base: base, force: force)
        }
        saveTasks[id] = task
        let r = await task.value
        if saveTasks[id] == task { saveTasks.removeValue(forKey: id) }
        return r
    }

    private func saveNow(_ id: String, text: String, base wanted: String??, force: Bool) async -> [String: Any] {
        guard let doc = docs[id] else { return ["error": "gone"] }
        // Read-only is the file's word, not the page's: a reload may have just made it so.
        if let reason = tabs.first(where: { $0.id == id })?.readOnly {
            return ["error": "read-only: \(reason)"]
        }
        let bytes = FileText.encode(text, eol: doc.eol, bom: doc.bom)
        let abs = doc.abs, base = wanted ?? doc.base
        let outcome = await onUtility { FileSave.save(bytes, to: abs, base: base, force: force) }
        let rel = relative(abs) ?? abs
        switch outcome {
        case .saved(let version, let fp):
            docs[id]?.base = version
            docs[id]?.fingerprint = fp
            docs[id]?.size = Int64(bytes.count)
            docs[id]?.diskSeen = nil
            diskReads.removeValue(forKey: id)
            banners.removeValue(forKey: id)
            FileRecovery.remove(path: abs)
            app?.audit.emit("fleetview.file.saved", categories: ["file"], message: "saved \(rel)",
                            data: ["path": .string(abs), "file.bytes": .int(bytes.count),
                                   "file.sha256": .string(version), "file.base": base.map { .string($0) } ?? .null,
                                   "forced": .bool(force), "source": .string("desktop")])
            requestStatus(after: 0.3)
            return ["ok": true]
        case .conflict(let current):
            docs[id]?.diskSeen = current
            banners[id] = .diskChanged
            app?.audit.emit("fleetview.file.save_conflict", categories: ["file"], message: "not saved, changed on disk: \(rel)",
                            data: ["path": .string(abs), "file.base": base.map { .string($0) } ?? .null,
                                   "file.sha256": current.map { .string($0) } ?? .null])
            return ["conflict": true]
        case .failed(let why):
            banners[id] = .failed(why)
            return ["error": why]
        }
    }

    enum UnsavedChoice { case save, discard, cancel }

    func askAboutUnsaved(_ list: [Tab], reason: String? = nil, _ done: @escaping (UnsavedChoice) -> Void) {
        let a = NSAlert()
        if list.count == 1 {
            a.messageText = L(.filesUnsavedOne((list[0].path as NSString).lastPathComponent))
        } else {
            a.messageText = L(.filesUnsavedMany(list.count))
        }
        a.informativeText = reason ?? L(.filesUnsavedBody)
        a.addButton(withTitle: list.count == 1 ? L(.save) : L(.filesSaveAll))
        a.addButton(withTitle: L(.cancel))
        a.addButton(withTitle: L(.filesDontSave))
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            switch r {
            case .alertFirstButtonReturn: done(.save)
            case .alertThirdButtonReturn: done(.discard)
            default: done(.cancel)
            }
        }
        if let window, window.isVisible { a.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(a.runModal()) }
    }

    /// Save these tabs' current text. `done(false)` when any of them could not be saved (its banner
    /// says why).
    func saveTabs(_ list: [Tab], done: @escaping (Bool) -> Void) {
        editor.call("dirtyTexts") { [weak self] result in
            guard let self else { return }
            let wanted = Set(list.map(\.id))
            let texts = (result as? [[String: Any]] ?? []).compactMap { e -> (String, String)? in
                guard let t = e["tab"] as? String, wanted.contains(t), let s = e["text"] as? String else { return nil }
                return (t, s)
            }
            Task {
                // A tab the page had no text for (its process died a moment ago) is not saved either.
                var ok = Set(texts.map(\.0)) == wanted
                for (tab, text) in texts {
                    let r = await self.save(tab, text: text)
                    if r["ok"] as? Bool == true { self.editor.call("markSaved", [tab, text]) } else { ok = false }
                }
                done(ok)
            }
        }
    }

    var unsavedTabs: [Tab] { tabs.filter(\.dirty) }

    func discardAll() {
        for t in unsavedTabs {
            // Removed now, not queued: "Don't Save" on quit is followed by the process going away.
            if let d = docs[t.id] { FileRecovery.remove(path: d.abs, now: true) }
            editor.call("discard", [t.id])
        }
    }

    // MARK: - Disk changes to open files

    private func watch(_ id: String) {
        guard let d = docs[id] else { return }
        watches[id] = FileWatch(path: d.abs) { [weak self] in self?.fileEvent(id) }
    }

    private func fileEvent(_ id: String) {
        guard let d = docs[id] else { return }
        // Small files are looked at after a short pause; mid-size ones at most every 5 s (a log being
        // appended to); huge ones are only compared by size and time.
        let wait: TimeInterval = d.size <= 1_000_000 ? 0.3 : (d.size <= 20_000_000 ? 5 : 0.5)
        scheduleCheck(id, after: wait)
    }

    private func scheduleCheck(_ id: String, after wait: TimeInterval) {
        checks[id]?.cancel()
        let t = DispatchWorkItem { [weak self] in Task { await self?.check(id) } }
        checks[id] = t
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: t)
    }

    /// Did the file under a tab change, and what to do about it.
    ///
    /// Size and time first, which cost a stat. Only for the tab in front of a window someone can
    /// see, and a file small enough, is it read and hashed: a tab out of sight is only marked, and
    /// looked at properly when it is shown. Everything is read again after each wait — the tab can
    /// have been saved, closed or typed into meanwhile.
    func check(_ id: String, recheck: Bool = false) async {
        guard let d = docs[id] else { return }
        guard let fp = FileSave.fingerprint(path: d.abs) else {
            // Gone — or a checkout deleting and recreating it. Look again before saying so.
            if !recheck {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await check(id, recheck: true)
            } else if docs[id] != nil {
                banners[id] = .deleted
            }
            return
        }
        watches[id]?.rearmIfReplaced()        // an agent's atomic write puts a new inode under the path
        if banners[id] == .deleted { banners.removeValue(forKey: id) }
        if fp == d.fingerprint { return }      // our own save, or nothing that changed the bytes
        guard tabs.contains(where: { $0.id == id }) else { return }
        if d.size > 20_000_000 || fp.size > 20_000_000 {
            // Not hashed, not reloaded on its own: the banner offers the disk's version.
            docs[id]?.diskSeen = nil
            banners[id] = .diskChanged
            return
        }
        guard id == activeTab && visible else { docs[id]?.stale = true; return }
        let abs = d.abs
        let version = await onUtility { FileManager.default.contents(atPath: abs).map(FileText.version) }
        guard let now = docs[id], let tabNow = tabs.first(where: { $0.id == id }) else { return }
        if version == now.base { docs[id]?.fingerprint = fp; return }
        if tabNow.dirty {
            docs[id]?.diskSeen = version
            banners[id] = .diskChanged
            return
        }
        _ = await editor.callAsync("reload", [id])
        if let e = FileEdits.shared.latest(for: abs), Date().timeIntervalSince(e.at) < 120 {
            showToast(L(.filesChangedBy(e.terminalName)))
        }
    }

    /// The banner's three ways out of a disk change under unsaved edits.
    func useDiskVersion(_ id: String) {
        editor.call("useDisk", [id]) { [weak self] ok in
            // Only once the page holds the disk's text: until then the edits are still the only copy.
            guard let self, ok as? Bool == true, let d = self.docs[id] else { return }
            self.banners.removeValue(forKey: id)
            FileRecovery.remove(path: d.abs)
        }
    }

    func compare(_ id: String) { editor.call("compare", [id]) }

    /// Replace what is on disk with the tab's text — the version the banner was about, not one an
    /// agent wrote after it: that is a conflict again, with a new banner.
    func overwrite(_ id: String) {
        editor.call("text", [id]) { [weak self] r in
            guard let self, let text = r as? String, let d = self.docs[id] else { return }
            Task {
                var seen = d.diskSeen
                if seen == nil {
                    let abs = d.abs
                    seen = await onUtility { FileManager.default.contents(atPath: abs).map(FileText.version) }
                }
                let out = await self.save(id, text: text, base: .some(seen))
                if out["ok"] as? Bool == true { self.editor.call("markSaved", [id, text]) }
            }
        }
    }

    func dismissBanner(_ id: String) { banners.removeValue(forKey: id) }

    // MARK: - Recovery

    private func offerRecovery(_ id: String) {
        guard var d = docs[id], !d.recoveryOffered else { return }
        d.recoveryOffered = true
        docs[id] = d
        guard let entry = FileRecovery.load(path: d.abs) else { return }
        banners[id] = .recovered(entry.at, sameBase: entry.base == d.base)
    }

    /// Put recovered edits back. They were made against the version recorded with them, which may
    /// not be the one on disk now: that version becomes the base (see `rebase`).
    func restoreRecovered(_ id: String) {
        guard let d = docs[id], let entry = FileRecovery.load(path: d.abs) else { return }
        banners.removeValue(forKey: id)
        editor.call("restore", [id, entry.text]) { [weak self] ok in
            if ok as? Bool == true { self?.rebase(id, to: entry.base) }
        }
    }

    func discardRecovered(_ id: String) {
        guard let d = docs[id] else { return }
        banners.removeValue(forKey: id)
        FileRecovery.remove(path: d.abs, now: true)
    }

    // MARK: - Small things

    func showToast(_ text: String) {
        toast = text
        toastTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: t)
    }

    func focusEditor() {
        guard !tabs.isEmpty else { return }
        window?.makeFirstResponder(editor.webView)
        editor.call("focus")
    }

    func copyPath(_ rel: String, relativeOnly: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(relativeOnly ? rel : absolute(rel), forType: .string)
        showToast(L(.filesCopied))
    }

    /// A file the user went to: the back/forward history and quick open's "recently opened".
    private func noteOpened(_ rel: String) {
        if selected != rel { selected = rel }
        recentOpened.removeAll { $0 == rel }
        recentOpened.insert(rel, at: 0)
        if recentOpened.count > 20 { recentOpened.removeLast() }
        noteVisit(rel)
    }

    // MARK: - Reference in a card

    /// The project's terminals that can take text now.
    var referenceTargets: [TerminalSession] {
        (app?.terminals(inProject: projectId) ?? []).filter { $0.status.isOpen }
    }

    /// Put the file's path into a terminal's input, without pressing Return.
    func reference(_ rel: String, in terminal: TerminalSession) {
        let abs = absolute(rel)
        var path = abs
        let cwd = URL(fileURLWithPath: (terminal.cwd as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        if abs.hasPrefix(cwd + "/") { path = String(abs.dropFirst(cwd.count + 1)) }
        guard let text = Self.referenceText(path, agent: terminal.agentKind) else { showToast(L(.filesReferenceOdd)); return }
        app?.insertText(terminal.id, text + " ", why: "file.reference")
        showToast(L(.filesReferenced(terminal.name)))
    }

    static func referenceText(_ path: String, agent: AgentKind) -> String? {
        PathReference.text(path, for: agent == .claude ? .claude : (agent == .codex ? .agent : .shell))
    }
}
