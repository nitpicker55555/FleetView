import SwiftUI

/// A terminal sitting on a turn. A struct (not a tuple) so the model can tell whether the chips
/// actually changed and skip republishing — hook events fire constantly while agents work.
struct TermChip: Equatable {
    let name: String
    let status: TermStatus
}

/// Hover follows the pointer, so it must NOT live on the model the rows observe: publishing it
/// there re-rendered every visible row on every mouse move, which is what made scrolling stutter.
/// Rows write here without observing it; only the floating inspector listens.
@MainActor
final class TreeFocus: ObservableObject {
    @Published var hovered: String?
    @Published var focusY: CGFloat?
}

/// View-model for the session-tree panel: loads/refreshes the tree on a background queue,
/// tracks selection, search, fold expansion, and where each attached terminal currently sits.
@MainActor
final class SessionTreeModel: ObservableObject {
    @Published private(set) var tree = TreeGraph()
    @Published private(set) var rows: [TreeRow] = []
    @Published private(set) var loading = false
    @Published private(set) var emptyReason: String?
    @Published var selected: String?          // clicked → full prompt + full reply
    /// Pointer-driven state, deliberately kept off this object (see TreeFocus).
    let focus = TreeFocus()
    @Published var query = "" { didSet { applyRows() } }
    /// Include assistant replies in the search, not just prompts.
    @Published var searchAnswers = true { didSet { applyRows() } }
    /// Newest turn first — the end of the conversation is what you came to look at.
    @Published var newestFirst = true { didSet { applyRows() } }

    /// nodeUuid → chips for terminals whose current session leaf sits on that node.
    @Published private(set) var chips: [String: [TermChip]] = [:]

    /// Where the tree comes from. The two backends store conversations nothing alike — Claude a
    /// directory per project, Codex a pile filed by date (see CodexTree) — but both arrive here as
    /// a `TreeGraph`, so everything below this line is shared.
    enum Source: Equatable {
        case claude(projectDir: URL)
        case codex(cwd: String)
    }
    private(set) var source: Source?
    /// The Claude project directory, when that is what this tree is. Callers that can only mean
    /// Claude (fork synthesis) ask for it and get nil otherwise, rather than guessing.
    var projectDir: URL? { if case .claude(let d) = source { return d }; return nil }
    private(set) var boundSessionId: String?
    private var sessionInfo: [String: [(name: String, status: TermStatus)]] = [:]
    private var expandedFolds: Set<String> = []
    private var refreshTimer: Timer?
    private var dirSignature = ""
    private var generation = 0
    /// A Codex signature walk is out on a background queue; a slow disk must not queue these up.
    private var signatureInFlight = false

    /// The turn the inspector shows: the pinned one, else whatever is hovered, else the live leaf.
    func detailNode(hovered: String?) -> TreeTurn? {
        for candidate in [selected, hovered, tree.activeLeafNode] {
            if let c = candidate, let n = tree.nodes[c] { return n }
        }
        return nil
    }

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Where a turn matched — the row shows this, so a hit inside a long reply doesn't look like
    /// a prompt match you can't find.
    func hits(_ node: TreeTurn) -> (prompt: Bool, answer: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return (false, false) }
        return (node.text.localizedCaseInsensitiveContains(q),
                searchAnswers && node.answer.localizedCaseInsensitiveContains(q))
    }

    /// The slice of a reply around the match, so the hit is actually visible on the row.
    func answerSnippet(_ node: TreeTurn) -> String {
        let flat = node.answer.replacingOccurrences(of: "\n", with: " ")
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let r = flat.range(of: q, options: .caseInsensitive) else {
            return flat
        }
        let lead = 24
        let start = flat.index(r.lowerBound, offsetBy: -lead,
                               limitedBy: flat.startIndex) ?? flat.startIndex
        let clipped = String(flat[start...])
        return (start > flat.startIndex ? "…" : "") + clipped
    }

    func matches(_ node: TreeTurn) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if node.text.localizedCaseInsensitiveContains(q) { return true }
        return searchAnswers && node.answer.localizedCaseInsensitiveContains(q)
    }

    // MARK: - Lifecycle

    /// `sessions`: sid → (terminal name, status) for every terminal attached to this conversation.
    func open(source: Source, boundSessionId: String?,
              sessions: [String: [(name: String, status: TermStatus)]]) {
        self.source = source
        self.boundSessionId = boundSessionId
        self.sessionInfo = sessions
        self.emptyReason = nil
        self.selected = nil
        self.focus.hovered = nil
        self.focus.focusY = nil
        self.expandedFolds = []
        reload(showSpinner: true)
        startRefresh()
    }

    func showEmpty(_ reason: String) {
        emptyReason = reason
        tree = TreeGraph()
        rows = []
        stopRefresh()
    }

    func close() {
        stopRefresh()
        rows = []
        tree = TreeGraph()
        emptyReason = nil
        source = nil
    }

    func expandFold(_ id: String) {
        expandedFolds.insert(id)
        applyRows()
    }

    // MARK: - Loading

    private func reload(showSpinner: Bool) {
        guard let src = source else { return }
        let sid = boundSessionId
        if showSpinner { loading = true }
        generation += 1
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let built: TreeGraph
            switch src {
            case .claude(let dir):
                built = SessionTreeBuilder.build(projectDir: dir, boundSessionId: sid)
            case .codex(let cwd):
                built = CodexTree.build(cwd: cwd, boundSessionId: sid, root: CodexSession.sessionsDir)
            }
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.loading = false
                if built.nodeCount == 0 {
                    self.showEmpty("这个会话还没有可显示的对话节点")
                    return
                }
                self.tree = built
                self.applyRows()
                self.applyChips()
            }
        }
    }

    private func applyRows() {
        var r = tree.rows
        for f in expandedFolds { r = SessionTreeBuilder.expandFold(r, foldId: f, tree: tree) }
        if searching {
            // Show ONLY hits — a dimmed haystack is still a haystack. Folds carry no text, so drop them.
            r = r.filter { row in
                guard let u = row.nodeUuid, let n = tree.nodes[u] else { return false }
                return matches(n)
            }
        }
        rows = newestFirst ? r.reversed() : r
    }

    private func applyChips() {
        var out: [String: [TermChip]] = [:]
        for (sid, infos) in sessionInfo {
            guard let node = tree.leafNodeBySession[sid] else { continue }
            for info in infos { out[node, default: []].append(TermChip(name: info.name, status: info.status)) }
        }
        if out != chips { chips = out }   // hook events are frequent; don't redraw rows for nothing
    }

    /// Called by AppState when terminal statuses change, so chips stay truthful without a reload.
    func updateSessions(_ sessions: [String: [(name: String, status: TermStatus)]]) {
        sessionInfo = sessions
        applyChips()
    }

    // MARK: - Live refresh (cheap stat poll; rebuild only when a file changed)

    private func startRefresh() {
        stopRefresh()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshTick() {
        guard let src = source else { return }
        switch src {
        case .claude(let dir):
            // A project directory holds dozens of files; stat-ing them is cheap enough to do here.
            let fm = FileManager.default
            let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
            var sig = ""
            for f in files.sorted(by: { $0.path < $1.path }) {
                let a = try? fm.attributesOfItem(atPath: f.path)
                sig += "\(f.lastPathComponent):\((a?[.size] as? Int64) ?? 0):\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0);"
            }
            applySignature(sig)
        case .codex(let cwd):
            // Codex's signature has to walk the whole date-filed store to notice a new rollout
            // (a fork IS a new file, which no per-file stat can see). That is ~27ms of directory
            // listing, and this fires every two seconds — nowhere near the main actor, which is
            // what drawing the board runs on.
            guard !signatureInFlight else { return }
            signatureInFlight = true
            let sid = boundSessionId
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let sig = CodexTree.signature(cwd: cwd, boundSessionId: sid,
                                              root: CodexSession.sessionsDir)
                Task { @MainActor in
                    guard let self else { return }
                    self.signatureInFlight = false
                    guard case .codex(let still)? = self.source, still == cwd else { return }
                    self.applySignature(sig)
                }
            }
        }
    }

    private func applySignature(_ sig: String) {
        if dirSignature.isEmpty { dirSignature = sig; return }
        if sig != dirSignature {
            dirSignature = sig
            reload(showSpinner: false)   // silent — selection and folds are preserved
        }
    }
}
