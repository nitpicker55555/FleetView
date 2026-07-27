import Foundation

/// One user turn in a session tree: the prompt, a short reply summary, and tree structure.
struct TreeNode: Codable {
    let u: String            // uuid of the user-prompt record (fork anchor)
    var p: String?           // parent TURN's uuid (nil = root)
    var ts: String?          // timestamp
    var prompt: String       // the user's text (truncated)
    var reply: String        // first assistant text of the turn (truncated)
    var session: String      // session id (file) this turn lives in
    var active: Bool = false // on THIS terminal's live path
    var own: Bool = false    // in this terminal's own session file
    var tip: Bool = false    // the live path's last turn
}

struct TreeResult: Codable {
    var nodes: [TreeNode] = []
    var session: String = ""      // this terminal's session id
    var branches: Int = 0         // nodes with >1 child
    var sessions: Int = 0         // distinct session files in the tree
    var error: String? = nil
}

/// Builds the conversation tree treeflow-style: read EVERY jsonl in the project dir into one
/// uuid→record index (a `--resume` or fork lives in a different file but chains to its origin via
/// parentUuid), pick the tree reachable from this terminal's session, and expose user turns as
/// nodes. Forking writes a fresh <new-sid>.jsonl (original lines untouched) pinned by a trailing
/// last-prompt record — a direct port of treeflow's write_synthetic_session.
enum SessionTree {

    // One parsed record we keep in memory: slim fields + the raw line (forks re-emit raw lines).
    struct Rec {
        let uuid: String
        let parent: String?
        let ts: String
        let session: String
        let isUserPrompt: Bool
        let isTurnBody: Bool     // assistant output or a tool result — the turn's own content
        let userText: String
        let asstText: String
        let cwd: String
        let raw: String
    }

    struct Index {
        var byUuid: [String: Rec] = [:]
        var children: [String: [String]] = [:]      // parent uuid → child uuids (file order)
        var sessionLeaf: [String: String] = [:]     // session id → latest leafUuid (last-prompt)
        var dir: URL
    }

    // MARK: - Load

    /// Load the whole project dir (all sessions). Transient; called on demand off the main thread.
    static func load(projectDir: URL) -> Index {
        var idx = Index(dir: projectDir)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            let sid = f.deletingPathExtension().lastPathComponent
            guard let data = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in data.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let d = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                if (obj["type"] as? String) == "last-prompt", let leaf = obj["leafUuid"] as? String {
                    idx.sessionLeaf[sid] = leaf
                    continue
                }
                guard let uuid = obj["uuid"] as? String else { continue }
                let rec = Rec(uuid: uuid,
                              parent: obj["parentUuid"] as? String,
                              ts: (obj["timestamp"] as? String) ?? "",
                              session: sid,
                              isUserPrompt: isUserPrompt(obj),
                              isTurnBody: isTurnBody(obj),
                              userText: clip(userText(obj), 400),
                              asstText: clip(asstText(obj), 400),
                              cwd: (obj["cwd"] as? String) ?? "",
                              raw: String(line))
                // First writer wins — identical uuids appear in multiple files after a fork/resume
                // copies the chain, and the original file is the earliest by sort order.
                if idx.byUuid[rec.uuid] == nil {
                    idx.byUuid[rec.uuid] = rec
                    if let p = rec.parent { idx.children[p, default: []].append(uuid) }
                }
            }
        }
        return idx
    }

    // MARK: - Tree

    /// The turn tree for one terminal's session, rooted at that session's chain root.
    static func build(transcriptPath: String) -> TreeResult {
        var out = TreeResult()
        let url = URL(fileURLWithPath: transcriptPath)
        let sid = url.deletingPathExtension().lastPathComponent
        out.session = sid
        guard transcriptPath.contains("/.claude/") else {
            out.error = "tree view supports Claude sessions only"
            return out
        }
        let idx = load(projectDir: url.deletingLastPathComponent())
        guard !idx.byUuid.isEmpty else { out.error = "empty session"; return out }

        // This terminal's live chain: session leaf → descend to the newest descendant → root.
        let leaf = currentTip(of: sid, idx)
        var activeChain = Set<String>()
        var cur = leaf
        while let u = cur, !activeChain.contains(u) {
            activeChain.insert(u)
            cur = idx.byUuid[u]?.parent
        }

        // Root of this conversation (walk up from the leaf across files).
        var root = leaf
        while let u = root, let p = idx.byUuid[u]?.parent, idx.byUuid[p] != nil { root = p }
        guard let rootUuid = root else { out.error = "no root"; return out }

        // Collect the user turns of the subtree under the root. Parent turn = nearest user-prompt
        // ancestor. DFS in file order keeps siblings chronological.
        var nodes: [TreeNode] = []
        var stack: [(uuid: String, lastTurn: String?)] = [(rootUuid, nil)]
        var turnChildren: [String: Int] = [:]
        var sessionsSeen = Set<String>()
        var lastActiveTurn: String?
        while let (u, lastTurn) = stack.popLast() {
            guard let rec = idx.byUuid[u] else { continue }
            var turnHere = lastTurn
            if rec.isUserPrompt {
                let onActive = activeChain.contains(u)
                var n = TreeNode(u: u, p: lastTurn, ts: rec.ts,
                                 prompt: rec.userText,
                                 reply: replySummary(of: u, idx),
                                 session: rec.session)
                n.active = onActive
                n.own = rec.session == sid
                nodes.append(n)
                if let lt = lastTurn { turnChildren[lt, default: 0] += 1 }
                if onActive { lastActiveTurn = u }
                sessionsSeen.insert(rec.session)
                turnHere = u
            }
            for child in (idx.children[u] ?? []).reversed() {
                stack.append((child, turnHere))
            }
        }
        // Turn order: by timestamp, so the list reads chronologically even across sibling files.
        nodes.sort { ($0.ts ?? "") < ($1.ts ?? "") }
        if let tipTurn = lastActiveTurn,
           let i = nodes.firstIndex(where: { $0.u == tipTurn }) { nodes[i].tip = true }
        out.nodes = nodes
        out.branches = turnChildren.values.filter { $0 > 1 }.count
        out.sessions = sessionsSeen.count
        return out
    }

    /// The newest record of a session's live chain: last-prompt leafUuid, descended to the newest
    /// child (replies land under the leaf after it is recorded), else the session's newest record.
    private static func currentTip(of sid: String, _ idx: Index) -> String? {
        var tip = idx.sessionLeaf[sid].flatMap { idx.byUuid[$0] != nil ? $0 : nil }
        if tip == nil {
            tip = idx.byUuid.values.filter { $0.session == sid }.max { $0.ts < $1.ts }?.uuid
        }
        var visited = Set<String>()
        while let u = tip, let kids = idx.children[u], let next = kids.last, !visited.contains(u) {
            visited.insert(u)
            tip = next
        }
        return tip
    }

    /// First assistant text under a turn (walking non-user descendants), for the node's summary.
    private static func replySummary(of turnUuid: String, _ idx: Index) -> String {
        var queue = idx.children[turnUuid] ?? []
        var visited = Set<String>()
        while !queue.isEmpty {
            let u = queue.removeFirst()
            guard !visited.contains(u), let rec = idx.byUuid[u], !rec.isUserPrompt else { continue }
            visited.insert(u)
            if !rec.asstText.isEmpty { return rec.asstText }
            queue.append(contentsOf: idx.children[u] ?? [])
        }
        return ""
    }

    // MARK: - Fork (treeflow's write_synthetic_session, ported)

    /// Fork the conversation at a node: new session file = ancestors(root→target) + target's reply
    /// chain (non-user descendants, timestamp order), pinned by a last-prompt record with a fresh
    /// session id. Original files are never modified. Returns (newSessionId, launchCwd).
    static func fork(transcriptPath: String, at targetUuid: String) -> (sid: String, cwd: String)? {
        let url = URL(fileURLWithPath: transcriptPath)
        let idx = load(projectDir: url.deletingLastPathComponent())
        return fork(idx, at: targetUuid, dir: url.deletingLastPathComponent())
    }

    /// Fork at the live tip's turn — what "duplicate" means for an agent terminal: a sibling that
    /// starts with the whole conversation so far.
    static func forkAtTip(transcriptPath: String) -> (sid: String, cwd: String)? {
        let url = URL(fileURLWithPath: transcriptPath)
        let sid = url.deletingPathExtension().lastPathComponent
        let idx = load(projectDir: url.deletingLastPathComponent())
        var cur = currentTip(of: sid, idx)
        while let u = cur, let rec = idx.byUuid[u], !rec.isUserPrompt { cur = rec.parent }
        guard let turn = cur else { return nil }
        return fork(idx, at: turn, dir: url.deletingLastPathComponent())
    }

    private static func fork(_ idx: Index, at targetUuid: String, dir: URL) -> (sid: String, cwd: String)? {
        guard let target = idx.byUuid[targetUuid] else { return nil }

        // Back chain: target + ancestors, oldest first.
        var back: [Rec] = []
        var cur: String? = targetUuid
        var seen = Set<String>()
        while let u = cur, !seen.contains(u), let rec = idx.byUuid[u] {
            seen.insert(u)
            back.append(rec)
            cur = rec.parent
        }
        back.reverse()

        // Forward chain: this turn's own body (assistant output + tool results), BFS so multi-step
        // reply/tool runs are captured in full. Whitelisting the body — rather than merely skipping
        // user prompts — is what keeps the NEXT turn out: an `attachment` record belonging to the
        // following prompt hangs off this turn's last assistant, so a blacklist leaks it (and with
        // it, everything that prompt said).
        var forward: [Rec] = []
        var visited: Set<String> = [targetUuid]
        var queue = [targetUuid]
        while !queue.isEmpty {
            let u = queue.removeFirst()
            for child in idx.children[u] ?? [] {
                guard !visited.contains(child), let rec = idx.byUuid[child], rec.isTurnBody else { continue }
                visited.insert(child)
                forward.append(rec)
                queue.append(child)
            }
        }
        forward.sort { $0.ts < $1.ts }
        let leafUuid = forward.last?.uuid ?? targetUuid

        let newSid = UUID().uuidString.lowercased()
        let lastPrompt: [String: Any] = ["type": "last-prompt",
                                         "lastPrompt": target.userText,
                                         "leafUuid": leafUuid,
                                         "sessionId": newSid]
        guard let lpData = try? JSONSerialization.data(withJSONObject: lastPrompt),
              let lpLine = String(data: lpData, encoding: .utf8) else { return nil }

        var body = (back + forward).map { $0.raw }.joined(separator: "\n")
        body += "\n" + lpLine + "\n"
        let newPath = dir.appendingPathComponent("\(newSid).jsonl")
        guard (try? body.write(to: newPath, atomically: true, encoding: .utf8)) != nil else { return nil }

        // Launch dir: the cwd the conversation actually ran in (its slug owns this project dir) —
        // the terminal's own cwd can differ when claude was started in a subdirectory.
        let cwd = !target.cwd.isEmpty ? target.cwd : (back.last(where: { !$0.cwd.isEmpty })?.cwd ?? "")
        return (newSid, cwd)
    }

    // MARK: - Record helpers (treeflow's _is_user_prompt semantics)

    private static func isUserPrompt(_ obj: [String: Any]) -> Bool {
        guard (obj["type"] as? String) == "user",
              (obj["isSidechain"] as? Bool) != true,
              (obj["isMeta"] as? Bool) != true else { return false }
        let content = (obj["message"] as? [String: Any])?["content"]
        if let blocks = content as? [[String: Any]] {
            for b in blocks where (b["type"] as? String) == "tool_result" { return false }
        }
        let text = userText(obj)
        // Skip slash-command echoes and harness-injected wrappers — not conversational turns.
        if text.isEmpty || text.hasPrefix("<command-") || text.hasPrefix("<local-command") { return false }
        return true
    }

    /// A turn's own content: the assistant's output, or a user record that is purely tool results.
    /// Deliberately excludes `attachment`, `system`, snapshots and prompts — those either belong to
    /// the next turn or aren't needed to replay this one.
    private static func isTurnBody(_ obj: [String: Any]) -> Bool {
        switch obj["type"] as? String {
        case "assistant":
            return true
        case "user":
            guard let blocks = ((obj["message"] as? [String: Any])?["content"]) as? [[String: Any]] else { return false }
            return blocks.contains { ($0["type"] as? String) == "tool_result" }
        default:
            return false
        }
    }

    private static func userText(_ obj: [String: Any]) -> String {
        let content = (obj["message"] as? [String: Any])?["content"]
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let blocks = content as? [[String: Any]] {
            for b in blocks where (b["type"] as? String) == "text" {
                if let t = b["text"] as? String {
                    let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { return s }
                }
            }
        }
        return ""
    }

    private static func asstText(_ obj: [String: Any]) -> String {
        guard (obj["type"] as? String) == "assistant",
              let blocks = ((obj["message"] as? [String: Any])?["content"]) as? [[String: Any]] else { return "" }
        for b in blocks where (b["type"] as? String) == "text" {
            if let t = b["text"] as? String {
                let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { return s }
            }
        }
        return ""
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}
