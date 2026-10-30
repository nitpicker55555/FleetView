import AppKit
import FleetViewFiles

/// The 提交 page and the tabs that show changes: a commit, the working tree, two versions.
///
/// Read when shown — the log when the page is opened and again when HEAD or the refs move, a
/// commit's files when its tab opens, one file's diff when it unfolds — never on a timer. All of it
/// read-only, through `GitReader` (see docs/design/2026-10-26-file-window-history.md).
extension FileBrowserModel {
    enum HistoryState: Equatable {
        case idle
        case loading(more: Bool)
        /// `more`: a full page came back, so there may be earlier commits.
        case loaded(more: Bool)
        case failed
    }

    /// Which changes a tab shows.
    struct ChangeSpec: Equatable {
        let repoFolder: String
        let range: GitRange
        /// The file to unfold and scroll to (project-relative).
        var focus: String?
        let title: String
        /// The commit, for a commit's tab.
        var sha: String?

        func same(_ o: ChangeSpec) -> Bool { repoFolder == o.repoFolder && range == o.range }
        var live: Bool { if case .worktree = range { return true }; return false }
    }

    /// One file of a changes tab, as served to its page.
    struct ChangeFile {
        let change: GitChange
        /// Where it is in the tree, nil when outside the project.
        let rel: String?
        let oldRel: String?
        let untrackedDir: Bool
    }

    static let pageSize = 100

    // MARK: - The page

    /// The 提交 page came into view.
    func historyShown() {
        if repo(folder: historyRepo) == nil, let first = defaultHistoryRepo() { historyRepo = first }
        if historyStale || commits.isEmpty { loadHistory() }
        loadBranches()
        loadCommitters()
    }

    private func defaultHistoryRepo() -> String? {
        if let a = active, a.kind != .changes, let r = repoFor(a.path) { return r.folder }
        return repos.first?.folder
    }

    /// The repositories changed (one was found inside the project).
    func historyReposChanged() {
        if repo(folder: historyRepo) == nil, let first = defaultHistoryRepo() {
            historyRepo = first
            historyStale = true
        }
        if sideMode == .history { historyShown() }
    }

    /// HEAD or a ref of this repository moved: the list may be out of date.
    func historyMoved(_ folder: String) {
        guard folder == historyRepo else { return }
        historyStale = true
        if sideMode == .history && visible {
            loadHistory()
            loadBranches()
        }
    }

    func setHistoryRepo(_ folder: String) {
        if historyCard != nil { clearCardFilter() }
        guard folder != historyRepo else { return }
        historyRepo = folder
        commitAuthors = [:]
        historyRef = nil
        historyPath = nil
        comparePick = nil
        commits = []
        loadHistory()
        loadBranches()
    }

    func setHistoryRef(_ ref: String?) {
        guard ref != historyRef else { return }
        historyRef = ref
        commits = []
        loadHistory()
    }

    /// "这个文件的历史": the commits that changed a file or folder.
    func showHistory(of rel: String) {
        if let r = repoFor(rel) { historyRepo = r.folder } else { showToast(L(.histNoRepo)); return }
        historyPath = rel
        historyRef = nil
        commits = []
        historyStale = true
        if sideMode != .history { sideMode = .history } else { loadHistory() }
    }

    func clearHistoryPath() {
        historyPath = nil
        commits = []
        loadHistory()
    }

    func loadHistory(more: Bool = false) {
        guard let r = repo(folder: historyRepo) else { commits = []; historyState = .idle; return }
        if case .loading = historyState, more { return }
        historyGeneration += 1
        let gen = historyGeneration
        let skip = more ? commits.count : 0
        historyState = .loading(more: more)
        var path = r.scope
        var follow = false
        if let p = historyPath {
            path = r.inRepo(p)
            var isDir: ObjCBool = false
            follow = !(FileManager.default.fileExists(atPath: absolute(p), isDirectory: &isDir) && isDir.boolValue)
        }
        let ref = historyRef, limit = Self.pageSize, logPath = path, logFollow = follow
        Task {
            let list = await onUtility { GitReader.shared.log(r.repo, ref: ref, path: logPath, follow: logFollow, skip: skip, limit: limit) }
            guard gen == self.historyGeneration else { return }
            self.historyStale = false
            guard let list else {
                if !more { self.commits = [] }
                // No commits yet is not a failure worth a word: the list is just empty.
                self.historyState = more ? .loaded(more: false) : .failed
                return
            }
            self.commits = more ? self.commits + list : list
            self.historyState = .loaded(more: list.count == limit)
            self.attributeCommits()
        }
    }

    func loadBranches() {
        guard let r = repo(folder: historyRepo) else { branchList = []; return }
        Task {
            let list = await onUtility { GitReader.shared.branches(r.repo) }
            if list != self.branchList { self.branchList = list }
        }
    }

    /// The branch HEAD is on in the page's repository.
    var historyCurrentBranch: String? {
        historyRepo.isEmpty ? branch : nestedBranches[historyRepo]
    }

    /// Uncommitted files in the page's repository (and under its file, when it shows one).
    var historyUncommitted: Int {
        guard let r = repo(folder: historyRepo) else { return 0 }
        let p = historyPath
        return marks.keys.filter { k in r.contains(k) && (p.map { k == $0 || k.hasPrefix($0 + "/") } ?? true) }.count
    }

    // MARK: - Opening changes

    func openCommit(_ sha: String, in folder: String? = nil, pin: Bool = false) {
        let f = folder ?? historyRepo
        let c = commits.first { $0.sha == sha } ?? cardCommits.first { $0.commit.sha == sha }?.commit
        let short = String(sha.prefix(7))
        let title = c.map { short + " " + $0.subject } ?? short
        openChanges(ChangeSpec(repoFolder: f, range: .commit(sha), focus: historyPath, title: title, sha: sha), pin: pin)
    }

    func openUncommitted() {
        openChanges(ChangeSpec(repoFolder: historyRepo, range: .worktree("HEAD"), focus: historyPath,
                               title: L(.histUncommittedTitle)), pin: false)
    }

    func compareWithWorktree(_ sha: String, in folder: String? = nil) {
        openChanges(ChangeSpec(repoFolder: folder ?? historyRepo, range: .worktree(sha), focus: historyPath,
                               title: L(.histVersusWorktree(String(sha.prefix(7))))), pin: true)
    }

    /// Two commits picked from the list: the older one is the base.
    func compare(_ a: String, _ b: String) {
        let ia = commits.firstIndex { $0.sha == a } ?? 0, ib = commits.firstIndex { $0.sha == b } ?? 0
        let (base, target) = ia >= ib ? (a, b) : (b, a)
        comparePick = nil
        openChanges(ChangeSpec(repoFolder: historyRepo, range: .between(base, target), focus: historyPath,
                               title: "\(base.prefix(7)) ↔ \(target.prefix(7))"), pin: true)
    }

    /// A branch against the current one, from where they parted — what a pull request would show.
    func compareBranch(_ name: String) {
        guard let r = repo(folder: historyRepo) else { return }
        Task {
            let base = await onUtility { GitReader.shared.mergeBase(r.repo, "HEAD", name) }
            guard let base else { self.showToast(L(.histNoMergeBase)); return }
            self.openChanges(ChangeSpec(repoFolder: r.folder, range: .between(base, name), focus: nil,
                                        title: L(.histBranchVersusCurrent(name))), pin: true)
        }
    }

    func openChanges(_ spec: ChangeSpec, pin: Bool) {
        if let i = tabs.firstIndex(where: { $0.changes?.same(spec) == true }) {
            if pin { tabs[i].pinned = true }
            let id = tabs[i].id
            activate(id)
            if let f = spec.focus { editor.call("jump", [id, ["file": f]]) }
            return
        }
        let id = UUID().uuidString
        var tab = Tab(id: id, path: "", pinned: pin, kind: .changes, mode: .source)
        tab.changes = spec
        placeTab(tab, pin: pin)
        activeTab = id
        status = Status()
        var meta: [String: Any] = ["kind": "changes", "path": "", "root": root, "title": spec.title, "live": spec.live]
        if let f = spec.focus { meta["focus"] = f }
        editor.call("open", [id, meta])
    }

    // MARK: - Serving the page

    func serveChanges(_ id: String) async -> EditorBridge.Response {
        guard let spec = tabs.first(where: { $0.id == id })?.changes, let r = repo(folder: spec.repoFolder) else { return .notFound }
        let range = spec.range, root = self.root
        // Untracked files come from the last status, which already knows them; git's diff does not.
        var found: [(String, Bool)] = []
        if case .worktree = range, let st = repoStatus(r.folder) {
            found = st.marks.filter { $0.value == .untracked }.keys.sorted().map { ($0, st.untracked.contains($0)) }
        }
        let untracked = found
        let result = await onUtility { () -> (files: [GitChange], commit: GitCommit?, message: String?, parent: String?)? in
            guard var files = GitReader.shared.changes(r.repo, range, under: r.scope) else { return nil }
            var commit: GitCommit?, message: String?, parent: String?
            if case .commit(let sha) = range {
                commit = GitReader.shared.commit(r.repo, sha)
                message = GitReader.shared.message(r.repo, sha)
                parent = commit?.parents.first
            }
            for (rel, isDir) in untracked.prefix(2000) {
                let path = r.inRepo(rel)
                if isDir {
                    files.append(GitChange(path: path + "/", oldPath: nil, status: "?", added: nil, deleted: nil, binary: false))
                    continue
                }
                let lines = Self.lineCount(root + "/" + rel)
                files.append(GitChange(path: path, oldPath: nil, status: "?", added: lines, deleted: lines == nil ? nil : 0,
                                       binary: lines == nil))
            }
            return (files, commit, message, parent)
        }
        guard let result else { return .json(500, ["kind": "error", "title": L(.histGitFailed)]) }
        let list = Array(result.files.prefix(3000))
        var entries: [ChangeFile] = []
        var json: [[String: Any]] = []
        var focus = -1
        for (i, c) in list.enumerated() {
            let dir = c.status == "?" && c.path.hasSuffix("/")
            let clean = dir ? String(c.path.dropLast()) : c.path
            let rel = r.project(clean)
            let oldRel = c.oldPath.flatMap { r.project($0) }
            entries.append(ChangeFile(change: c, rel: rel, oldRel: oldRel, untrackedDir: dir))
            var e: [String: Any] = ["i": i, "path": rel ?? clean, "status": c.status, "binary": c.binary, "dir": dir,
                                    "lang": Self.language(for: clean, sniff: false)]
            if let rel { e["rel"] = rel }
            if let o = c.oldPath { e["old"] = oldRel ?? o }
            if let a = c.added { e["add"] = a }
            if let d = c.deleted { e["del"] = d }
            json.append(e)
            if let f = spec.focus, focus < 0, rel == f || oldRel == f { focus = i }
        }
        changeFiles[id] = entries
        var out: [String: Any] = ["title": spec.title, "files": json, "focus": focus, "more": result.files.count - list.count]
        switch range {
        case .commit(let sha):
            out["kind"] = "commit"
            out["a"] = result.parent.map { String($0.prefix(7)) } ?? ""
            out["b"] = String(sha.prefix(7))
            if let c = result.commit {
                var cj: [String: Any] = ["sha": c.sha, "short": c.short, "parents": c.parents, "author": c.author,
                                         "date": c.date.timeIntervalSince1970, "refs": c.refs, "coAuthors": c.coAuthors,
                                         "message": result.message ?? c.subject]
                if let a = c.agent { cj["agent"] = a }
                if let f = c.files { cj["files"] = f }
                if let a = c.added { cj["added"] = a }
                if let d = c.deleted { cj["deleted"] = d }
                out["commit"] = cj
            }
        case .between(let a, let b):
            out["kind"] = "between"
            out["a"] = Self.revLabel(a)
            out["b"] = Self.revLabel(b)
        case .worktree(let a):
            out["kind"] = "worktree"
            out["a"] = Self.revLabel(a)
            out["b"] = ""
        }
        return .json(200, out)
    }

    private static func revLabel(_ rev: String) -> String {
        rev.count == 40 && rev.allSatisfy(\.isHexDigit) ? String(rev.prefix(7)) : rev
    }

    /// Lines in a small text file, nil for a binary or a large one (not counted, not diffed).
    nonisolated static func lineCount(_ abs: String) -> Int? {
        guard let k = kindOf(abs), k.type == S_IFREG, k.size <= 2_000_000,
              let data = FileManager.default.contents(atPath: abs), !FileText.isBinary(data) else { return nil }
        if data.isEmpty { return 0 }
        let n = data.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        return data.last == 10 ? n : n + 1
    }

    private func changeFile(_ rest: String) -> (spec: ChangeSpec, r: RepoRef, file: ChangeFile, parts: [String])? {
        let parts = rest.split(separator: "/").map(String.init)
        guard parts.count >= 2, let i = Int(parts[1]), let files = changeFiles[parts[0]], files.indices.contains(i),
              let spec = tabs.first(where: { $0.id == parts[0] })?.changes, let r = repo(folder: spec.repoFolder) else { return nil }
        return (spec, r, files[i], parts)
    }

    /// `patch/<tab>/<i>`: one file's unified diff.
    func servePatch(_ rest: String) async -> EditorBridge.Response {
        guard let (spec, r, f, _) = changeFile(rest) else { return .notFound }
        let c = f.change
        if c.status == "?" {
            // Untracked: the whole file is new. Read here rather than diffed against nothing by git.
            guard !f.untrackedDir, let rel = f.rel else { return .notFound }
            let abs = absolute(rel)
            let text = await onUtility { () -> String? in
                guard Self.lineCount(abs) != nil, let data = FileManager.default.contents(atPath: abs),
                      let d = FileText.decode(data) else { return nil }
                return d.text
            }
            guard let text else { return .json(415, ["binary": true]) }
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            let patch = "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 }.joined(separator: "\n") + "\n"
            return EditorBridge.Response(status: 200, mime: "text/plain; charset=utf-8", data: Data(patch.utf8))
        }
        let paths = [c.oldPath, c.path].compactMap { $0 }
        let range = spec.range
        let result = await onUtility { GitReader.shared.patch(r.repo, range, paths: paths) }
        guard let result else { return .json(500, ["error": L(.histGitFailed)]) }
        return EditorBridge.Response(status: 200, mime: "text/plain; charset=utf-8", data: result.text,
                                     headers: result.truncated ? ["X-FV-Truncated": "1"] : [:])
    }

    /// `blob/<tab>/<i>/<a|b>`: one side of a file, for the side-by-side view.
    func serveBlob(_ rest: String) async -> EditorBridge.Response {
        guard let (spec, r, f, parts) = changeFile(rest), parts.count == 3 else { return .notFound }
        let c = f.change, side = parts[2]
        let empty = EditorBridge.Response(status: 200, mime: "text/plain; charset=utf-8", data: Data())
        if side == "a" && (c.status == "A" || c.status == "?") { return empty }
        if side == "b" && c.status == "D" { return empty }
        let range = spec.range
        let data: Data? = await onUtility {
            let g = GitReader.shared
            if side == "a" {
                let path = c.oldPath ?? c.path
                switch range {
                case .commit(let sha): return g.firstParent(r.repo, of: sha).flatMap { g.blob(r.repo, rev: $0, path: path) } ?? Data()
                case .between(let a, _), .worktree(let a): return g.blob(r.repo, rev: a, path: path)
                }
            }
            switch range {
            case .commit(let sha), .between(_, let sha): return g.blob(r.repo, rev: sha, path: c.path)
            case .worktree: return FileManager.default.contents(atPath: r.repo.toplevel + "/" + c.path)
            }
        }
        guard let data else { return .notFound }
        guard !FileText.isBinary(data), let text = FileText.decode(data) else { return .json(415, ["binary": true]) }
        return EditorBridge.Response(status: 200, mime: "text/plain; charset=utf-8", data: Data(text.text.utf8))
    }
}
