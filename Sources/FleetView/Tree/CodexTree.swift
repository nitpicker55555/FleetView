import Foundation

/// The session tree for Codex, built into the same `TreeGraph` the Claude panel renders.
///
/// Nothing about Codex's storage helps. Rollouts are filed by DATE, not by project, so there is no
/// directory that means "this conversation"; and a fork copies the parent's turns into a new file
/// **with every timestamp rewritten to the fork moment** — measured on this corpus: 589 turns
/// identical in text, not one identical in time. So neither the filesystem nor the clock can stitch
/// a tree, and `forked_from_id` names the parent session without saying where the split happened.
///
/// What survives copying is the conversation itself. Identity here is therefore a chain hash over
/// prompt text: a turn's id folds in every prompt before it, so a copied prefix produces exactly the
/// same ids as the original and the first divergence produces different ones. The fork attaches at
/// the point it actually forked without anything having had to record where that was — and two
/// sessions that merely *begin* alike stay merged only for as long as they really are alike.
///
/// Nodes are ADDRESSED the way treeflow addresses them — `<session-id>:<n>`, n counting user
/// prompts in file order — because that address is what opens a node (see `SearchOpen.planCodex`,
/// and `SearchIndex`, which numbers its hits identically). Identity dedupes; the address names. A
/// shared turn takes the address of the earliest session holding it, so a fork points at the
/// original rather than at its own copy.
enum CodexTree {

    /// A rollout's head record, which is fixed for the life of the file.
    struct Meta {
        let path: String
        let sid: String
        let cwd: String
        let started: String       // ISO8601 from the head record; also the sort key
        let forkedFrom: String?
        /// Set when this rollout is a worker spawned by another thread, never when it is a
        /// conversation someone typed into. Kept rather than dropped so a terminal that has been
        /// attributed to a worker can still be walked back to the conversation it belongs to.
        let parentThread: String?
        var isMainLine: Bool { parentThread == nil }
    }

    // MARK: - The rollout index

    /// Heads are immutable once written, so this is keyed by path alone. It matters: a full index
    /// pass opens ~2000 files and each head runs to ~19 KB (Codex puts the whole base instruction
    /// set on it), and the panel's refresh tick would otherwise pay that every two seconds.
    private static var metaCache: [String: Meta?] = [:]
    private static let lock = NSLock()

    /// Every rollout under `root`, newest directories first. Codex files them as
    /// `sessions/YYYY/MM/DD/rollout-*.jsonl`; walking the three levels by name costs no `stat`.
    static func rolloutPaths(root: URL) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for y in (try? fm.contentsOfDirectory(atPath: root.path))?.sorted() ?? [] {
            let yp = root.appendingPathComponent(y)
            for m in (try? fm.contentsOfDirectory(atPath: yp.path))?.sorted() ?? [] {
                let mp = yp.appendingPathComponent(m)
                for d in (try? fm.contentsOfDirectory(atPath: mp.path))?.sorted() ?? [] {
                    let dp = mp.appendingPathComponent(d)
                    for f in (try? fm.contentsOfDirectory(atPath: dp.path)) ?? []
                    where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                        out.append(dp.appendingPathComponent(f).path)
                    }
                }
            }
        }
        return out
    }

    /// The main-line sessions recorded against `cwd`, oldest first.
    ///
    /// Sub-threads are excluded the way Claude's builder drops sidechains: a multi-agent run spawns
    /// a rollout per worker (1775 of the 2068 here), each of which would root its own mini-tree in
    /// a panel that is supposed to be showing one conversation. `parent_thread_id` is the marker and
    /// it is never a session's own id, so its mere presence means "this thread has a parent".
    static func sessions(cwd: String, root: URL) -> [Meta] {
        guard !cwd.isEmpty else { return [] }
        var out: [Meta] = []
        for p in rolloutPaths(root: root) {
            guard let m = meta(p), m.isMainLine, m.cwd == cwd else { continue }
            out.append(m)
        }
        // Oldest first, so the ORIGINAL of a shared prefix claims the address and a fork points at
        // it. Ties break on the filename, which carries the same timestamp and is unique.
        return out.sorted { ($0.started, $0.path) < ($1.started, $1.path) }
    }

    static func meta(_ path: String) -> Meta? {
        lock.lock()
        if let hit = metaCache[path] { lock.unlock(); return hit }
        lock.unlock()

        let parsed = readMeta(path)
        lock.lock(); metaCache[path] = parsed; lock.unlock()
        return parsed
    }

    private static func readMeta(_ path: String) -> Meta? {
        guard let obj = headObject(path),
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String else { return nil }
        let sid = (payload["id"] as? String)
            ?? (payload["session_id"] as? String)
            ?? sessionId(fromRollout: path)
        return Meta(path: path, sid: sid, cwd: cwd,
                    started: (payload["timestamp"] as? String)
                        ?? (obj["timestamp"] as? String) ?? "",
                    forkedFrom: payload["forked_from_id"] as? String,
                    parentThread: payload["parent_thread_id"] as? String)
    }

    /// The conversation a rollout belongs to: itself if someone typed in it, otherwise the thread
    /// that spawned it, walked to the top.
    ///
    /// This is not a corner case. A multi-agent run writes one rollout per worker — 637 of them
    /// against this project, versus 47 real conversations — and they share the project's cwd, so
    /// "the newest rollout in this directory" (how a Codex terminal is attributed at all, see
    /// `CodexSession.currentRollout`) lands on a worker most of the time while a run is going. A
    /// tree opened on such a terminal has to show the conversation, not nothing.
    static func mainLineSession(of sid: String, root: URL) -> String? {
        var index: [String: Meta] = [:]
        for p in rolloutPaths(root: root) {
            if let m = meta(p) { index[m.sid] = m }
        }
        var cur = sid
        var seen: Set<String> = []
        while let m = index[cur], let up = m.parentThread, seen.insert(cur).inserted {
            cur = up
        }
        return index[cur]?.isMainLine == true ? cur : nil
    }

    /// The first line, read in chunks: `session_meta` carries the whole base-instruction block and
    /// runs past any fixed-size read, and a truncated line parses as nothing at all.
    private static func headObject(_ path: String) -> [String: Any]? {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? h.close() }
        var buf = Data()
        while buf.count < 1_048_576 {
            guard let chunk = try? h.read(upToCount: 65_536), !chunk.isEmpty else { break }
            buf.append(chunk)
            if buf.firstIndex(of: 0x0A) != nil { break }
        }
        let end = buf.firstIndex(of: 0x0A) ?? buf.endIndex
        return (try? JSONSerialization.jsonObject(with: buf.subdata(in: buf.startIndex..<end)))
            as? [String: Any]
    }

    /// `rollout-2026-07-19T02-14-32-<uuid>.jsonl` → `<uuid>`. Same rule as SearchIndex's, so the
    /// two agree on what a session is called even when the head record is unreadable.
    static func sessionId(fromRollout path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let parts = name.split(separator: "-")
        guard parts.count >= 5 else { return name }
        return parts.suffix(5).joined(separator: "-")
    }

    // MARK: - Turns

    struct Turn {
        let n: Int            // treeflow's prompt index within this rollout
        let text: String
        var answer: String
        let ts: String
        /// A `context_compacted` event landed between the previous prompt and this one.
        var compactedBefore: Bool = false
    }

    private struct TurnCache { let size: Int64; let mtime: TimeInterval; let turns: [Turn] }
    private static var turnCache: [String: TurnCache] = [:]

    /// A rollout's user prompts, with the agent messages that answered each folded in.
    ///
    /// Read from `response_item` messages, which is where treeflow reads them and — since Codex
    /// 0.147 — the only place they exist. Rollouts used to carry a parallel `event_msg` stream
    /// (`user_message` / `agent_message`) and this counted those instead; the two happened to agree
    /// because the extra `response_item` copies were exactly the `<environment_context>` blocks
    /// treeflow filters out. Verified on a July rollout: 80 event_msg prompts, 85 response_item
    /// ones, 80 after the filter. The new format dropped the event_msg stream, so that reading
    /// found nothing at all and every Codex session showed an empty tree.
    ///
    /// The numbering still has to match treeflow's exactly or a node's address opens the wrong
    /// turn: a prompt treeflow keeps but this considers unshowable still advances the counter,
    /// while one treeflow never counted (the environment blocks) must not. This mirrors
    /// `SearchIndex.parseCodex`, deliberately — the tree and the search index address the same
    /// nodes and must not drift apart.
    static func turns(of path: String) -> [Turn] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        lock.lock()
        if let c = turnCache[path], c.size == size, c.mtime == mtime {
            lock.unlock(); return c.turns
        }
        lock.unlock()

        var out: [Turn] = []
        var n = 0
        // Held until the next prompt: a compaction happens between turns, and the turn that has to
        // carry the mark is the first one that ran without what came before it.
        var compactionPending = false
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) {
            // Byte-level fast reject before any JSON. A rollout is overwhelmingly `response_item`
            // tool traffic — the same records `SearchIndex` skips for the same reason — and decoding
            // it only to throw it away is the whole cost: on this corpus it was 15.8s to build one
            // project's tree, against 0.6s once the reject went in.
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let p = raw.bindMemory(to: UInt8.self)
                var lo = 0
                while lo < p.count {
                    var hi = lo
                    while hi < p.count, p[hi] != 0x0A { hi += 1 }
                    defer { lo = hi + 1 }
                    // Probed on the raw bytes, ahead of the role reject that would otherwise drop
                    // the line: a `context_compacted` event carries no role at all, so it never
                    // survives to be parsed.
                    //
                    // The literal is only a filter, and the record is then decoded and checked,
                    // because those same bytes can appear inside a prompt or a tool output — and
                    // swallowing one of those would drop a turn, which shifts every node address
                    // after it and opens the wrong turn (see the numbering note above). A line that
                    // merely mentions the word falls through to the normal path.
                    guard hi > lo, p[lo] == UInt8(ascii: "{") else { continue }
                    if contains(p, lo, hi, Self.compactedKey),
                       let obj = (try? JSONSerialization.jsonObject(
                           with: Data(raw[lo..<hi]))) as? [String: Any],
                       (obj["type"] as? String) == "event_msg",
                       ((obj["payload"] as? [String: Any])?["type"] as? String) == "context_compacted" {
                        compactionPending = true
                        continue
                    }
                    guard contains(p, lo, hi, Self.roleKey),
                          let obj = (try? JSONSerialization.jsonObject(
                              with: Data(raw[lo..<hi]))) as? [String: Any],
                          (obj["type"] as? String) == "response_item",
                          let payload = obj["payload"] as? [String: Any],
                          (payload["type"] as? String) == "message",
                          let role = payload["role"] as? String else { continue }
                    let ts = (obj["timestamp"] as? String) ?? ""
                    switch role {
                    case "user":
                        let raw = contentText(payload)
                        // Not a turn at all, in treeflow's counting or ours — skipping it before the
                        // counter is what keeps the two numbering schemes on the same items.
                        guard isRealUserText(raw) else { continue }
                        defer { n += 1 }
                        guard let t = cleanPrompt(raw) else { continue }
                        out.append(Turn(n: n, text: clip(t, SessionTreeBuilder.promptCap),
                                        answer: "", ts: ts, compactedBefore: compactionPending))
                        compactionPending = false
                    case "assistant":
                        guard !out.isEmpty, let t = trimmed(contentText(payload)) else { continue }
                        // A reply belongs to the prompt it answers — the last one seen.
                        let i = out.count - 1
                        guard out[i].answer.count < SessionTreeBuilder.answerCap else { continue }
                        out[i].answer = clip(out[i].answer.isEmpty ? t : out[i].answer + "\n" + t,
                                             SessionTreeBuilder.answerCap)
                    default:
                        continue
                    }
                }
            }
        }
        lock.lock(); turnCache[path] = TurnCache(size: size, mtime: mtime, turns: out); lock.unlock()
        return out
    }

    /// Only message items carry a role, and only they carry a turn; the rest of a rollout is
    /// reasoning and tool traffic. A better reject than the record type itself — `response_item` is
    /// the majority of the file, `"role":` is 8-12% of it.
    private static let roleKey: [UInt8] = Array(#""role":""#.utf8)
    private static let compactedKey: [UInt8] = Array(#""context_compacted""#.utf8)

    /// The text of a `response_item` message, joined across its content blocks.
    /// Mirrors treeflow's `_codex_extract_text`.
    static func contentText(_ payload: [String: Any]) -> String {
        guard let blocks = payload["content"] as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for b in blocks {
            let t = (b["text"] as? String) ?? (b["input_text"] as? String)
                ?? (b["output_text"] as? String) ?? ""
            if !t.isEmpty { parts.append(t) }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Codex injects `<environment_context>` and `<turn_aborted>` blocks as role=user messages.
    /// treeflow (`_codex_is_real_user_text`) never counts them, so neither can we — an extra item
    /// in the index shifts every node address after it by one.
    static func isRealUserText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return !t.hasPrefix("<environment_context>") && !t.hasPrefix("<turn_aborted>")
    }

    /// Substring search over a raw line. A fast *reject* only — everything it keeps is still
    /// validated by the real JSON parse.
    private static func contains(_ p: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int,
                                 _ needle: [UInt8]) -> Bool {
        let n = needle.count
        guard n > 0, hi - lo >= n else { return false }
        let first = needle[0]
        var i = lo
        let last = hi - n
        while i <= last {
            if p[i] == first {
                var j = 1
                while j < n, p[i + j] == needle[j] { j += 1 }
                if j == n { return true }
            }
            i += 1
        }
        return false
    }

    /// Same noise list as the search index: records Codex writes as if the user had typed them.
    private static let noise = ["<local-command", "<command-name", "<command-message",
                                "<command-args", "<system-reminder", "<user-memory",
                                "Caveat: The messages below", "[Request interrupted",
                                "<bash-input", "<bash-stdout", "<bash-stderr"]

    private static func cleanPrompt(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !noise.contains(where: { t.hasPrefix($0) }) else { return nil }
        if let r = t.range(of: "<system-reminder>"), r.lowerBound != t.startIndex {
            t = String(t[t.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t.isEmpty ? nil : t
    }

    private static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    // MARK: - Build

    /// The sessions that make up ONE conversation: the bound session, whatever it forked from
    /// (transitively), and whatever forked from any of those.
    ///
    /// Scoping matters more here than it looks. A project directory accumulates unrelated Codex
    /// sessions — 47 against this one, 1.1 GB of rollout, of which the panel displays the single
    /// subtree the terminal is sitting in. Parsing the other 46 buys nothing and costs seconds.
    /// It is also *more correct*: two conversations that merely open with the same prompt ("继续")
    /// would otherwise hash alike and be drawn as one tree that branched, which is a lie.
    ///
    /// So `forked_from_id` decides WHICH sessions belong together — it is Codex's own record of a
    /// fork — and the content chain decides WHERE they diverge, which is the part Codex does not
    /// write down.
    static func family(of sid: String?, among metas: [Meta]) -> [Meta] {
        guard let start = sid ?? metas.last?.sid else { return [] }
        var byId: [String: Meta] = [:]
        var children: [String: [String]] = [:]
        for m in metas {
            byId[m.sid] = m
            if let f = m.forkedFrom { children[f, default: []].append(m.sid) }
        }
        guard byId[start] != nil else { return [] }
        var seen: Set<String> = [start]
        var queue = [start]
        while let s = queue.popLast() {
            if let up = byId[s]?.forkedFrom, byId[up] != nil, seen.insert(up).inserted {
                queue.append(up)
            }
            for down in children[s] ?? [] where seen.insert(down).inserted {
                queue.append(down)
            }
        }
        return metas.filter { seen.contains($0.sid) }   // keeps the oldest-first order
    }

    /// The session whose tree to show, given whatever the terminal was attributed to: itself when
    /// it is one of `all`, a stale index re-read when it is not, and the conversation above it when
    /// the terminal turned out to be sitting on a worker thread.
    private static func resolveBound(_ sid: String?, _ all: inout [Meta],
                                     cwd: String, root: URL) -> String? {
        guard let sid, !all.contains(where: { $0.sid == sid }) else { return sid }
        // A session started since the index was last built is not in it yet, and it is precisely
        // the one being asked about. Re-read once rather than showing the wrong conversation.
        forgetIndex()
        all = sessions(cwd: cwd, root: root)
        if all.contains(where: { $0.sid == sid }) { return sid }
        return mainLineSession(of: sid, root: root)
    }

    /// Build the tree for the conversation `boundSessionId` belongs to (see `family`).
    static func build(cwd: String, boundSessionId: String?, root: URL) -> TreeGraph {
        var tree = TreeGraph()
        var all = sessions(cwd: cwd, root: root)
        let bound = resolveBound(boundSessionId, &all, cwd: cwd, root: root)
        let metas = family(of: bound, among: all)
        guard !metas.isEmpty else { return tree }

        var canonical: [UInt64: String] = [:]      // chain hash → the address that owns that turn
        for m in metas {
            var chain: UInt64 = 0xcbf29ce484222325
            var parent: String?
            var leaf: String?
            for t in turns(of: m.path) {
                chain = fold(chain, t.text)
                let addr: String
                if let owner = canonical[chain] {
                    addr = owner                    // this turn is a copy of one we already have
                } else {
                    addr = "\(m.sid):\(t.n)"
                    canonical[chain] = addr
                    tree.nodes[addr] = TreeTurn(uuid: addr, parent: parent, text: t.text, ts: t.ts)
                    tree.nodes[addr]?.compactedBefore = t.compactedBefore
                    if let p = parent { tree.nodes[p]?.children.append(addr) }
                }
                // The copy may carry a reply the original was still writing when it was forked.
                if tree.nodes[addr]?.answer.isEmpty == true, !t.answer.isEmpty {
                    tree.nodes[addr]?.answer = t.answer
                }
                parent = addr
                leaf = addr
            }
            guard let leaf else { continue }
            tree.sessionLeaf[m.sid] = leaf
            tree.leafNodeBySession[m.sid] = leaf
            // `codex resume <sid>` continues a session at its end, so its last turn is reachable
            // with no fork at all — the same meaning `nativeSessionId` has on the Claude side.
            if tree.nodes[leaf]?.nativeSessionId == nil { tree.nodes[leaf]?.nativeSessionId = m.sid }
        }
        guard !tree.nodes.isEmpty else { return tree }

        SessionTreeBuilder.finish(&tree, boundSessionId: bound)
        return tree
    }

    /// FNV-1a, folded turn by turn. Not a security boundary — it only has to make "the same
    /// conversation so far" collide and anything else not, over a few thousand turns.
    private static func fold(_ seed: UInt64, _ s: String) -> UInt64 {
        var h = seed
        h = (h ^ 0x0a) &* 0x100000001b3         // separator, so prompts cannot run together
        for b in s.utf8 {
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        return h
    }

    /// Files whose size/mtime the panel watches to decide a rebuild is needed. Scoped to the same
    /// family the tree was built from, so an unrelated session growing in the background does not
    /// rebuild a tree it cannot appear in.
    static func watchPaths(cwd: String, boundSessionId: String?, root: URL) -> [String] {
        var all = sessions(cwd: cwd, root: root)
        let bound = resolveBound(boundSessionId, &all, cwd: cwd, root: root)
        return family(of: bound, among: all).map(\.path)
    }

    /// A new rollout appears as a new *file*, which no per-file signature can notice — so the
    /// refresh tick has to be told when the index itself is stale.
    static func forgetIndex() {
        lock.lock(); metaCache.removeAll(); indexedCount = -1; lock.unlock()
    }

    private static var indexedCount = -1

    /// What the panel polls to decide whether to rebuild: the family's files, plus how many
    /// rollouts exist at all.
    ///
    /// The count is the part that matters and the part a per-file stat cannot supply — forking a
    /// session writes a *new* rollout, so the thing that changed is that a file appeared. When the
    /// count moves, the cached head index is dropped so the new session can be seen; the walk is
    /// name-only (no `stat`), which is what keeps it affordable at this interval.
    static func signature(cwd: String, boundSessionId: String?, root: URL) -> String {
        let paths = rolloutPaths(root: root)
        lock.lock()
        let changed = paths.count != indexedCount
        if changed { indexedCount = paths.count }
        lock.unlock()
        if changed { lock.lock(); metaCache.removeAll(); lock.unlock() }

        var sig = "n=\(paths.count);"
        for p in watchPaths(cwd: cwd, boundSessionId: boundSessionId, root: root).sorted() {
            let a = try? FileManager.default.attributesOfItem(atPath: p)
            sig += "\(p):\((a?[.size] as? Int64) ?? 0):"
                + "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0);"
        }
        return sig
    }
}
