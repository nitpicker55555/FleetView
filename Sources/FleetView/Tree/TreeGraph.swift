import Foundation

/// The session-tree engine behind the desktop "会话树" panel — a Swift port of treeflow's
/// `load_project` + `build_nodes` (the user's own tool; see docs/design/2026-07-27-session-tree.md).
///
/// A Claude project directory is one uuid graph: every record carries `uuid`/`parentUuid`, and
/// forked/resumed sessions copy ancestor records into new files, so reading EVERY `.jsonl` in the
/// slug directory and deduping by uuid stitches the whole tree — including branches living in other
/// session files. Tree nodes are **user prompts**; assistant output aggregates onto the prompt that
/// owns it.

// MARK: - Models

/// One record, slimmed to what the tree needs (raw lines are re-read by SessionForge at fork time).
struct SlimRecord {
    let uuid: String
    let parent: String?
    let isPrompt: Bool        // a real user prompt (treeflow `_is_user_prompt`)
    let isAssistant: Bool
    let sidechain: Bool
    let ts: String            // ISO8601 — lexicographic order == chronological order
    let text: String          // prompt text or assistant text blocks (clipped)
}

/// One user-prompt node of the tree.
struct TreeTurn {
    let uuid: String
    var parent: String?       // nearest user-prompt ancestor
    var children: [String] = []
    let text: String
    let ts: String
    var answer: String = ""   // aggregated assistant reply text (clipped)
    var nativeSessionId: String?  // stock `claude --resume <sid>` lands exactly here
    /// Single-line, row-sized excerpts. Rows show two lines and one line respectively, so handing
    /// SwiftUI the full multi-thousand-character text just to clip it is what made scrolling stall.
    var preview: String = ""
    var answerPreview: String = ""
}

/// A display row: either a node or a fold pill covering a linear run.
struct TreeRow: Identifiable {
    enum Kind { case node(String); case fold(id: String, hidden: [String]) }
    let kind: Kind
    let laneDepth: Int          // 0 = the active/main lane
    let colorIndex: Int         // -1 = accent (active lane); 0..n = branch palette
    let isBranchFirst: Bool     // draw the connect curve from the parent lane
    let isBranchLast: Bool      // branch line ends below this row (fade out)
    let passLanes: [(depth: Int, colorIndex: Int)]   // ancestor lanes drawn straight through
    let branchChildCount: Int   // >0 ⇒ branch point (⑂N badge)
    let onActivePath: Bool
    let isCurrentLeaf: Bool
    let mainLanePasses: Bool    // the accent lane runs through this row
    let mainStartsHere: Bool    // root row: accent lane starts at the dot
    let mainEndsHere: Bool      // current-leaf row: accent lane ends at the dot

    var id: String {
        switch kind {
        case .node(let u): return u
        case .fold(let f, _): return f
        }
    }
    var nodeUuid: String? { if case .node(let u) = kind { return u }; return nil }
}

/// The built tree plus everything the panel renders.
struct TreeGraph {
    var nodes: [String: TreeTurn] = [:]
    var rows: [TreeRow] = []
    var rootUuid: String?
    var activeLeafNode: String?          // user-prompt node owning the bound session's leaf
    var activePath: Set<String> = []
    var branchPoints = 0
    var nodeCount = 0
    var totalBytes: Int64 = 0
    var sessionLeaf: [String: String] = [:]   // sid → leafUuid (per file's last `last-prompt`)
    /// sid → user-prompt node its leaf resolves to (placement for terminal chips).
    var leafNodeBySession: [String: String] = [:]
}

// MARK: - Builder

enum SessionTreeBuilder {
    static let answerCap = 2400
    static let promptCap = 4000
    /// What a row can actually show (2 lines / 1 line at ~13px in a ~380pt panel).
    static let previewCap = 200
    static let answerPreviewCap = 160
    /// Linear runs on the main lane longer than this fold into a "⋯ N turns" pill,
    /// keeping `foldKeep` nodes visible at each end of the run.
    static let foldThreshold = 7
    static let foldKeep = 2

    // MARK: File parsing (cached)

    private struct FileCache { let size: Int64; let mtime: TimeInterval
                               let records: [SlimRecord]; let leaf: String? }
    private static var cache: [String: FileCache] = [:]
    private static let cacheLock = NSLock()

    /// Parse one session file into slim records (+ its last `last-prompt` leaf pointer),
    /// cached by (size, mtime) so reopening the panel and refresh ticks are cheap.
    static func parseFile(_ url: URL) -> (records: [SlimRecord], leaf: String?, bytes: Int64) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        cacheLock.lock()
        if let c = cache[url.path], c.size == size, c.mtime == mtime {
            cacheLock.unlock()
            return (c.records, c.leaf, size)
        }
        cacheLock.unlock()

        var records: [SlimRecord] = []
        var leaf: String?
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return ([], nil, size) }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.first == "{", let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "last-prompt", let l = obj["leafUuid"] as? String { leaf = l; continue }
            guard let uuid = obj["uuid"] as? String else { continue }
            let msg = obj["message"] as? [String: Any]
            let content = msg?["content"]
            let isUser = type == "user"
            let isAssistant = type == "assistant"
            var isPrompt = false
            var text = ""
            if isUser {
                isPrompt = isUserPrompt(content)
                if isPrompt {
                    text = clip(userText(content), promptCap)
                    if isMetaPrompt(text) { isPrompt = false; text = "" }
                }
            } else if isAssistant {
                text = clip(userText(content), answerCap)   // same extraction: text blocks joined
            }
            records.append(SlimRecord(uuid: uuid,
                                      parent: obj["parentUuid"] as? String,
                                      isPrompt: isPrompt,
                                      isAssistant: isAssistant,
                                      sidechain: (obj["isSidechain"] as? Bool) ?? false,
                                      ts: (obj["timestamp"] as? String) ?? "",
                                      text: text))
        }
        cacheLock.lock()
        cache[url.path] = FileCache(size: size, mtime: mtime, records: records, leaf: leaf)
        cacheLock.unlock()
        return (records, leaf, size)
    }

    /// treeflow `_is_user_prompt`: a user record whose content has NO tool_result block and
    /// carries real text.
    private static func isUserPrompt(_ content: Any?) -> Bool {
        if let blocks = content as? [[String: Any]] {
            for b in blocks where (b["type"] as? String) == "tool_result" { return false }
        }
        return !userText(content).isEmpty
    }

    /// Records the CLI writes as if the user had typed them: slash-command plumbing and
    /// interruption markers. They are not turns, so they must not become tree nodes — their
    /// children reparent to the nearest real prompt above, which is where they belong anyway.
    /// Matching is deliberately prefix-anchored: real prompts do start with "[" (e.g. a pasted
    /// image or a bracketed label), and only these exact openers are synthetic.
    private static let metaPrefixes = [
        "<local-command",      // <local-command-caveat> / <local-command-stdout>
        "<command-name",       // the slash command itself
        "<command-message",
        "<command-args",
        "[Request interrupted",
    ]

    private static func isMetaPrompt(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return metaPrefixes.contains { t.hasPrefix($0) }
    }

    private static func userText(_ content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = content as? [[String: Any]] else { return "" }
        let parts = blocks.compactMap { b -> String? in
            guard (b["type"] as? String) == "text",
                  let t = (b["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else { return nil }
            return t
        }
        return parts.joined(separator: "\n")
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    private static func oneLine(_ s: String, _ n: Int) -> String {
        clip(s.replacingOccurrences(of: "\n", with: " "), n)
    }

    // MARK: Tree building

    /// Build the tree for the project directory containing `transcriptPath`, rooted at the subtree
    /// that contains `boundSessionId`'s leaf (the terminal this panel was opened from).
    static func build(projectDir: URL, boundSessionId: String?) -> TreeGraph {
        var tree = TreeGraph()

        let files = ((try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }   // treeflow: sorted glob, first uuid wins

        // by_uuid across ALL files (dedup: first occurrence wins), skipping subagent sidechains —
        // they root separate mini-trees that would pollute the panel.
        var byUuid: [String: SlimRecord] = [:]
        for f in files {
            let (records, leaf, bytes) = parseFile(f)
            tree.totalBytes += bytes
            if let leaf { tree.sessionLeaf[(f.lastPathComponent as NSString).deletingPathExtension] = leaf }
            for r in records where !r.sidechain {
                if byUuid[r.uuid] == nil { byUuid[r.uuid] = r }
            }
        }
        guard !byUuid.isEmpty else { return tree }

        // Nearest user-prompt ancestor (walks through assistant/tool records).
        func userParent(_ uuid: String) -> String? {
            var cur = byUuid[uuid]?.parent
            var seen = Set<String>()
            while let c = cur, !seen.contains(c) {
                seen.insert(c)
                guard let r = byUuid[c] else { return nil }
                if r.isPrompt { return c }
                cur = r.parent
            }
            return nil
        }
        /// The user-prompt node that OWNS a record (the record itself if it is a prompt).
        func owningPrompt(_ uuid: String) -> String? {
            guard let r = byUuid[uuid] else { return nil }
            return r.isPrompt ? uuid : userParent(uuid)
        }

        // Nodes.
        for (u, r) in byUuid where r.isPrompt {
            tree.nodes[u] = TreeTurn(uuid: u, parent: userParent(u), text: r.text, ts: r.ts)
        }
        for (u, n) in tree.nodes {
            if let p = n.parent { tree.nodes[p]?.children.append(u) }
        }
        let tsOf = tree.nodes.mapValues(\.ts)   // snapshot — sorting mutates tree.nodes
        for u in tree.nodes.keys {              // chronological child order (ISO sorts lexicographically)
            tree.nodes[u]?.children.sort { (tsOf[$0] ?? "") < (tsOf[$1] ?? "") }
        }

        // answer_text aggregation.
        for (u, r) in byUuid where r.isAssistant && !r.text.isEmpty {
            guard let owner = userParent(u), tree.nodes[owner] != nil else { continue }
            var acc = tree.nodes[owner]!.answer
            if acc.count < answerCap {
                acc = acc.isEmpty ? r.text : acc + "\n" + r.text
                tree.nodes[owner]!.answer = clip(acc, answerCap)
            }
        }

        // Row-sized excerpts, computed once here rather than on every scroll tick.
        for u in tree.nodes.keys {
            guard var n = tree.nodes[u] else { continue }
            n.preview = oneLine(n.text, previewCap)
            n.answerPreview = oneLine(n.answer, answerPreviewCap)
            tree.nodes[u] = n
        }

        // native_reachable: sessions whose stock --resume lands on a node (first claim wins).
        for (sid, leaf) in tree.sessionLeaf.sorted(by: { $0.key < $1.key }) {
            guard let node = owningPrompt(leaf) else { continue }
            tree.leafNodeBySession[sid] = node
            if tree.nodes[node]?.nativeSessionId == nil { tree.nodes[node]?.nativeSessionId = sid }
        }

        // Active leaf / path: the bound terminal's session, else the newest session leaf.
        var leafNode: String?
        if let sid = boundSessionId, let n = tree.leafNodeBySession[sid] { leafNode = n }
        if leafNode == nil {
            leafNode = tree.leafNodeBySession.values.max { (tree.nodes[$0]?.ts ?? "") < (tree.nodes[$1]?.ts ?? "") }
        }
        if leafNode == nil {   // no leaf pointers at all — newest prompt
            leafNode = tree.nodes.values.max { $0.ts < $1.ts }?.uuid
        }
        guard let leaf = leafNode else { return tree }
        tree.activeLeafNode = leaf
        var cur: String? = leaf
        var guardSet = Set<String>()
        while let c = cur, !guardSet.contains(c) {
            guardSet.insert(c)
            tree.activePath.insert(c)
            cur = tree.nodes[c]?.parent
        }
        tree.rootUuid = guardSet.first { tree.nodes[$0]?.parent == nil } ??
                        tree.activePath.first { tree.nodes[$0]?.parent == nil }

        (tree.nodeCount, tree.branchPoints) = subtreeStats(tree, tree.rootUuid)
        tree.rows = buildRows(tree)
        return tree
    }

    /// (node count, branch points) of the displayed subtree — scoped to what the panel shows,
    /// not the whole forest in the directory.
    private static func subtreeStats(_ tree: TreeGraph, _ root: String?) -> (Int, Int) {
        guard let root else { return (0, 0) }
        var n = 0, b = 0, stack = [root]
        var seen = Set<String>()
        while let u = stack.popLast() {
            guard !seen.contains(u) else { continue }
            seen.insert(u); n += 1
            let kids = tree.nodes[u]?.children ?? []
            if kids.count > 1 { b += 1 }
            stack.append(contentsOf: kids)
        }
        return (n, b)
    }

    // MARK: Rows + lanes

    /// Flatten the display subtree into ordered rows, oldest at top → current leaf at bottom.
    /// At a branch point the non-continuation subtrees (abandoned attempts, other terminals'
    /// branches) are emitted first on their own colored side lane; the continuation (active-path
    /// child if any, else the newest) stays on the parent's lane. Iterative — chains run hundreds
    /// of nodes deep and background threads have small stacks.
    private static func buildRows(_ tree: TreeGraph) -> [TreeRow] {
        guard let root = tree.rootUuid else { return [] }
        var rows: [TreeRow] = []
        var colorCounter = 0

        struct Frame { let uuid: String; let depth: Int; let color: Int
                       let isFirst: Bool; let pass: [(Int, Int)] }
        var stack: [Frame] = [Frame(uuid: root, depth: 0, color: -1, isFirst: false, pass: [])]

        while let f = stack.popLast() {
            let node = tree.nodes[f.uuid]
            let children = node?.children ?? []
            let continuation = children.first { tree.activePath.contains($0) } ?? children.last
            let others = children.filter { $0 != continuation }
            let onActive = tree.activePath.contains(f.uuid)
            let isLeafRow = f.uuid == tree.activeLeafNode
            let mainPasses = f.depth > 0 || !isLeafRow   // accent lane runs until the current leaf

            rows.append(TreeRow(kind: .node(f.uuid),
                                laneDepth: f.depth,
                                colorIndex: f.color,
                                isBranchFirst: f.isFirst,
                                isBranchLast: f.depth > 0 && continuation == nil,
                                passLanes: f.pass,
                                branchChildCount: others.count,
                                onActivePath: onActive,
                                isCurrentLeaf: isLeafRow,
                                mainLanePasses: f.depth == 0 ? true : mainPasses,
                                mainStartsHere: f.depth == 0 && f.uuid == root,
                                mainEndsHere: f.depth == 0 && isLeafRow))

            // LIFO: push continuation FIRST so side branches are emitted before it…
            if let cont = continuation {
                stack.append(Frame(uuid: cont, depth: f.depth, color: f.color,
                                   isFirst: false, pass: f.pass))
            }
            // …then side branches in REVERSE time order (stack pops newest-pushed first ⇒
            // they render oldest-first between this row and the continuation).
            var childPass = f.pass
            if f.depth > 0 && continuation != nil { childPass.append((f.depth, f.color)) }
            for o in others.reversed() {
                let c = colorCounter % TreeLane.paletteCount
                colorCounter += 1
                stack.append(Frame(uuid: o, depth: min(f.depth + 1, 2), color: c,
                                   isFirst: true, pass: childPass))
            }
        }
        return foldLinearRuns(rows, tree: tree)
    }

    /// Collapse long linear runs on the main lane into fold pills (branch points, the root, the
    /// current leaf and side-branch rows never fold).
    private static func foldLinearRuns(_ rows: [TreeRow], tree: TreeGraph) -> [TreeRow] {
        func foldable(_ r: TreeRow) -> Bool {
            r.laneDepth == 0 && r.branchChildCount == 0 && !r.isCurrentLeaf
                && !r.mainStartsHere && r.nodeUuid != nil
        }
        var out: [TreeRow] = []
        var i = 0
        while i < rows.count {
            var j = i
            while j < rows.count, foldable(rows[j]) { j += 1 }
            let run = j - i
            if run > foldThreshold {
                let keptHead = Array(rows[i ..< i + foldKeep])
                let hidden = Array(rows[(i + foldKeep) ..< (j - foldKeep)]).compactMap(\.nodeUuid)
                let keptTail = Array(rows[(j - foldKeep) ..< j])
                out.append(contentsOf: keptHead)
                out.append(TreeRow(kind: .fold(id: "fold-\(hidden.first ?? "")", hidden: hidden),
                                   laneDepth: 0, colorIndex: -1, isBranchFirst: false,
                                   isBranchLast: false, passLanes: [], branchChildCount: 0,
                                   onActivePath: true, isCurrentLeaf: false,
                                   mainLanePasses: true, mainStartsHere: false, mainEndsHere: false))
                out.append(contentsOf: keptTail)
            } else if run > 0 {
                out.append(contentsOf: rows[i ..< j])
            }
            if j < rows.count { out.append(rows[j]); j += 1 }
            i = j
        }
        return out
    }

    /// Re-expand one fold: rebuild the row list with the fold's nodes shown.
    static func expandFold(_ rows: [TreeRow], foldId: String, tree: TreeGraph) -> [TreeRow] {
        var out: [TreeRow] = []
        for r in rows {
            if case .fold(let id, let hidden) = r.kind, id == foldId {
                for u in hidden {
                    out.append(TreeRow(kind: .node(u), laneDepth: 0, colorIndex: -1,
                                       isBranchFirst: false, isBranchLast: false, passLanes: [],
                                       branchChildCount: 0, onActivePath: true, isCurrentLeaf: false,
                                       mainLanePasses: true, mainStartsHere: false, mainEndsHere: false))
                }
            } else {
                out.append(r)
            }
        }
        return out
    }
}

/// Lane geometry + the branch color palette (user request: distinct colors where branches multiply).
enum TreeLane {
    static let railWidth: CGFloat = 48
    static func x(_ depth: Int) -> CGFloat { 20 + CGFloat(min(depth, 2)) * 16 }
    static let paletteCount = 5
}
