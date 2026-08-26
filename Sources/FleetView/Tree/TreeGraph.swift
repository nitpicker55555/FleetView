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
    /// Set only on a `compact_boundary` record, so its presence *means* "a compaction starts here".
    /// That record has no `parentUuid` at all — a compacted session begins a fresh chain — and names
    /// the conversation it continues in `logicalParentUuid` instead. Without reading it, everything
    /// before the compaction is a separate tree in the same directory that nothing points at.
    let logicalParent: String?
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
    /// This turn opened on a freshly compacted context.
    ///
    /// Only Codex sets it, and that is the whole difference between the two backends here. Claude
    /// compacts by starting a *new session file* whose earlier half is a separate tree — hence the
    /// pill that goes and fetches it. Codex compacts in place: it writes one `context_compacted`
    /// event into the same rollout and carries on, so the turns before it are already in this tree,
    /// a few rows up. There is nothing to expand — only something to say, which is that the agent
    /// stopped being able to see them here.
    var compactedBefore: Bool = false
}

/// A display row: a node, a fold pill covering a linear run, or the compaction the tree starts on.
struct TreeRow: Identifiable {
    enum Kind {
        case node(String)
        case fold(id: String, hidden: [String])
        /// The top of a compacted session: release the earlier half into the tree. Distinct from a
        /// fold because a fold hides rows that are already built, while this one has to rebuild the
        /// graph with an edge it deliberately did not follow. `turns` is nil when that earlier half
        /// is no longer on disk — there is still something to say, just nothing to press.
        case compacted(boundary: String, turns: Int?)
    }
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
        case .compacted(let b, _): return "compact-\(b)"
        }
    }
    var nodeUuid: String? { if case .node(let u) = kind { return u }; return nil }
}

/// A compaction the tree stopped at: the conversation carries on above it, unread.
///
/// `ancestor` is nil when the earlier half is not in this project directory any more. On the machine
/// this was written on that is 1 boundary in 47 — but it sits at the top of a chain, so it is also
/// what you land on after expanding everything, which makes it the common ending rather than a rare
/// case. Saying "it is not here" answers the question the continued-from turn raises; showing
/// nothing answers it the same way as a conversation that simply started there.
struct CompactLink {
    let boundary: String      // the compact_boundary record's uuid — what "expanded" is keyed by
    let ancestor: String?     // the turn the compacted session continues from
    let turns: Int            // how many turns expanding would add, so the pill can say so
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
    /// Root turn → the compaction it sits on top of, for roots whose earlier half has not been
    /// expanded. Absent once it has been: the edge is then real and the ancestors are just parents.
    var compactedFrom: [String: CompactLink] = [:]
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
            let boundary = (obj["subtype"] as? String) == "compact_boundary"
            records.append(SlimRecord(uuid: uuid,
                                      parent: obj["parentUuid"] as? String,
                                      isPrompt: isPrompt,
                                      isAssistant: isAssistant,
                                      sidechain: (obj["isSidechain"] as? Bool) ?? false,
                                      ts: (obj["timestamp"] as? String) ?? "",
                                      text: text,
                                      logicalParent: boundary ? obj["logicalParentUuid"] as? String
                                                              : nil))
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
    ///
    /// `expandedCompactions` holds the `compact_boundary` uuids the user has asked to see behind.
    /// The link is not followed by default and that is the whole design: `compactMetadata` on these
    /// records routinely reports a preTokens of a million, so grafting the earlier half unasked
    /// would replace the conversation someone opened the panel to read with one they did not.
    static func build(projectDir: URL, boundSessionId: String?,
                      expandedCompactions: Set<String> = []) -> TreeGraph {
        var tree = TreeGraph()

        let files = ((try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }   // treeflow: sorted glob, first uuid wins

        // Every record's timestamp, ahead of the dedup below, which needs to compare a record with
        // its parent before either is settled. `parseFile` is cached by (size, mtime), so the
        // second pass re-reads nothing.
        var tsOf: [String: String] = [:]
        for f in files {
            for r in parseFile(f).records where !r.sidechain { tsOf[r.uuid] = r.ts }
        }
        /// A copy whose parent was written *after* it. Compaction re-emits the tail of the
        /// conversation it kept, re-parented onto the new summary, so those copies claim an
        /// ancestor from minutes into their own future.
        func reparented(_ r: SlimRecord) -> Bool {
            guard let p = r.parent, let pts = tsOf[p], !pts.isEmpty, !r.ts.isEmpty else { return false }
            return pts > r.ts
        }

        // by_uuid across ALL files, skipping subagent sidechains — they root separate mini-trees
        // that would pollute the panel.
        //
        // Dedup was first-occurrence-wins, which is fine while the copies agree. They do not always:
        // in one project here 18 records of 25,004 carry two different parents, and they are exactly
        // the 18 that join a compacted session to the conversation it continued. Sorted by filename,
        // the re-parented copy won, and the chain leaving a compacted session climbed 18 records and
        // arrived back at its own summary. Preferring the copy whose parent predates it follows the
        // same chain into 2,005 records of real history instead.
        var byUuid: [String: SlimRecord] = [:]
        for f in files {
            let (records, leaf, bytes) = parseFile(f)
            tree.totalBytes += bytes
            if let leaf { tree.sessionLeaf[(f.lastPathComponent as NSString).deletingPathExtension] = leaf }
            for r in records where !r.sidechain {
                guard let have = byUuid[r.uuid] else { byUuid[r.uuid] = r; continue }
                if reparented(have), !reparented(r) { byUuid[r.uuid] = r }
            }
        }
        guard !byUuid.isEmpty else { return tree }

        // Nearest user-prompt ancestor, walking up through assistant and tool records — and, for a
        // compaction the user has expanded, on through the boundary into the conversation it
        // continues. An unexpanded boundary ends the walk, which is what keeps the earlier half out
        // of the tree until it is asked for.
        func climb(from start: String?, throughCompactions: Bool = true) -> String? {
            var cur = start
            var seen = Set<String>()
            while let c = cur, !seen.contains(c) {
                seen.insert(c)
                guard let r = byUuid[c] else { return nil }
                if r.isPrompt { return c }
                if let logical = r.logicalParent, r.parent == nil {
                    cur = (throughCompactions && expandedCompactions.contains(c)) ? logical : nil
                } else {
                    cur = r.parent
                }
            }
            return nil
        }

        /// Does this link point at the turn's own future rather than at a previous conversation?
        ///
        /// Two of the boundaries in this directory resolve to a record *below* themselves, so the
        /// turn would come out its own parent. The walk is over raw `parentUuid` only — never
        /// through another boundary — because the question is about one unbroken chain.
        func pointsIntoOwnFuture(_ ancestor: String, of turn: String) -> Bool {
            var cur: String? = ancestor
            var seen = Set<String>()
            while let c = cur, !seen.contains(c) {
                if c == turn { return true }
                seen.insert(c)
                cur = byUuid[c]?.parent
            }
            return false
        }
        func userParent(_ uuid: String) -> String? { climb(from: byUuid[uuid]?.parent) }

        /// The compaction directly above a turn, when there is one and it has not been stepped
        /// through. Stops at the first real ancestor: a turn with a prompt above it continues
        /// something in the ordinary way and is not sitting on a boundary at all.
        func boundaryAbove(_ uuid: String) -> SlimRecord? {
            var cur = byUuid[uuid]?.parent
            var seen = Set<String>()
            while let c = cur, !seen.contains(c) {
                seen.insert(c)
                guard let r = byUuid[c] else { return nil }
                if r.isPrompt { return nil }
                if r.parent == nil { return r.logicalParent != nil ? r : nil }
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

        // What was not followed. Only for a turn that ends up a root: anywhere else the walk found
        // a real parent, and a boundary further up is already somebody else's pill.
        for (u, n) in tree.nodes where n.parent == nil {
            guard let b = boundaryAbove(u), let logical = b.logicalParent else { continue }
            let ancestor = climb(from: logical, throughCompactions: false)
            // Validated before it is ever offered, which is also what makes following it safe:
            // clicking a pill is the only way a uuid reaches `expandedCompactions`, so a link
            // rejected here can never become an edge.
            if let a = ancestor, pointsIntoOwnFuture(a, of: u) { continue }
            tree.compactedFrom[u] = CompactLink(boundary: b.uuid, ancestor: ancestor, turns: 0)
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

        // native_reachable: sessions whose stock --resume lands on a node (first claim wins).
        for (sid, leaf) in tree.sessionLeaf.sorted(by: { $0.key < $1.key }) {
            guard let node = owningPrompt(leaf) else { continue }
            tree.leafNodeBySession[sid] = node
            if tree.nodes[node]?.nativeSessionId == nil { tree.nodes[node]?.nativeSessionId = sid }
        }

        // How much expanding would add: the whole tree the ancestor belongs to, which is exactly
        // what appears once the edge is real. Counted here rather than promised vaguely — "展开压缩
        // 前的对话" with no number gives no way to tell a handful of turns from a thousand.
        for (u, link) in tree.compactedFrom {
            guard var root = link.ancestor else { continue }
            var seen = Set<String>()
            while let p = tree.nodes[root]?.parent, !seen.contains(p) { seen.insert(p); root = p }
            tree.compactedFrom[u] = CompactLink(boundary: link.boundary, ancestor: link.ancestor,
                                                turns: subtreeStats(tree, root).0)
        }

        finish(&tree, boundSessionId: boundSessionId)
        return tree
    }

    /// Everything both backends do once their nodes, edges, answers and session leaves exist.
    ///
    /// Shared because it is all downstream of the graph rather than of the format: Codex records
    /// nothing like a `parentUuid` and stores its sessions by date instead of by project (see
    /// CodexTree), but once the turns are linked, "which lane, which row, what folds, where is the
    /// live leaf" is the same question and must have the same answer — the panel, the inspector and
    /// the drag targets all read this shape and nothing else.
    static func finish(_ tree: inout TreeGraph, boundSessionId: String?) {
        // Chronological child order (ISO timestamps sort lexicographically).
        let tsOf = tree.nodes.mapValues(\.ts)   // snapshot — sorting mutates tree.nodes
        for u in tree.nodes.keys {
            tree.nodes[u]?.children.sort { (tsOf[$0] ?? "") < (tsOf[$1] ?? "") }
        }

        // Row-sized excerpts, computed once here rather than on every scroll tick.
        for u in tree.nodes.keys {
            guard var n = tree.nodes[u] else { continue }
            n.preview = oneLine(n.text, previewCap)
            n.answerPreview = oneLine(n.answer, answerPreviewCap)
            tree.nodes[u] = n
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
        guard let leaf = leafNode else { return }
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
        // The compaction the root sits on, if it has one: a row above the first turn, where the
        // conversation actually carries on. It takes over `mainStartsHere` from the root so the
        // accent lane begins at the pill and runs unbroken into the turns below it.
        let compacted = tree.compactedFrom[root]
        if let link = compacted {
            rows.append(TreeRow(kind: .compacted(boundary: link.boundary,
                                                 turns: link.ancestor == nil ? nil : link.turns),
                                laneDepth: 0, colorIndex: -1, isBranchFirst: false,
                                isBranchLast: false, passLanes: [], branchChildCount: 0,
                                onActivePath: true, isCurrentLeaf: false,
                                mainLanePasses: true, mainStartsHere: true, mainEndsHere: false))
        }

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
                                mainStartsHere: f.depth == 0 && f.uuid == root && compacted == nil,
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
        // `nodeUuid != tree.rootUuid` rather than `!mainStartsHere`: the two said the same thing
        // until a compaction pill took that flag over, and the rule was always "never fold the
        // root away" — not "never fold the row the lane happens to start on".
        func foldable(_ r: TreeRow) -> Bool {
            r.laneDepth == 0 && r.branchChildCount == 0 && !r.isCurrentLeaf
                && r.nodeUuid != nil && r.nodeUuid != tree.rootUuid
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
