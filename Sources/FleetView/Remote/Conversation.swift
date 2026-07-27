import Foundation

/// One normalized message in the web conversation view. Both Claude and Codex transcripts are
/// parsed into this shape so the page renders a single, simple format.
/// One before/after pair from an edit tool — the web view renders it as a diff.
struct ConvEdit: Codable {
    let old: String
    let new: String
}

struct ConvMsg: Codable {
    let role: String        // "user" | "assistant" | "tool" | "system"
    let kind: String        // "text" | "thinking" | "tool"
    var text: String        // message text, or a one-line tool summary
    var tool: String?       // tool name (kind == "tool")
    var cat: String?        // terminal | edit | read | search | web | task | other
    var detail: String?     // tool input detail (when there's nothing better to show)
    var output: String?     // tool result (truncated)
    var ok: Bool?           // tool succeeded
    var ts: String?         // ISO timestamp
    var sub: Bool           // from a subagent / sidechain
    var file: String? = nil       // file an edit touched
    var edits: [ConvEdit]? = nil  // Edit / MultiEdit / Write → rendered as a diff
    var patch: String? = nil      // Codex apply_patch → already a patch, just colourised
    var pending: Bool = false     // tool call with no result yet → still running, or awaiting approval
}

/// One tappable choice parsed off the agent's on-screen prompt (e.g. "1. Yes"), so a permission
/// request can be answered from the web with a button instead of guessing a digit.
struct ConvOption: Codable {
    let n: String
    let label: String
}

/// Session-level facts shown around the conversation: which model, what permission mode, how full
/// the context window is, and what (if anything) the agent is blocked on.
struct ConvInfo: Codable {
    var model: String? = nil
    var permissionMode: String? = nil
    var contextTokens: Int = 0
    var contextWindow: Int = 0
    var status: String? = nil          // terminal status, so the composer can offer Stop while working
    var shared: Int = 0                // terminals sharing this session (>1 ⇒ same chat by design)
    var branches: Int = 0              // branch points in the session tree (abandoned attempts)
    var session: String? = nil         // session id, so it's clear WHICH conversation this is
    var shell: Bool = false            // no agent conversation — show the pane's scrollback instead
    var pendingTool: String? = nil     // tool the agent is running or waiting on approval for
    var pendingText: String? = nil
    var question: String? = nil        // the prompt line shown on screen
    var options: [ConvOption] = []     // choices parsed off the screen
}

struct ConvResult: Codable {
    let messages: [ConvMsg]
    var info: ConvInfo
}

/// Reads an agent transcript (Claude Code `.jsonl` or Codex rollout `.jsonl`) and turns it into a
/// plain list of messages for the web "conversation" view. This is what makes remote reading work on
/// a phone: structured messages render with native scrolling instead of mirroring a full-screen TUI.
enum Conversation {
    /// Only the tail of the file is parsed — Codex rollouts reach tens of MB and we just want the
    /// recent conversation. 1.5 MB comfortably covers hundreds of messages.
    private static let tailBytes: UInt64 = 1_500_000

    /// - Parameter ownPrompt: this terminal's last submitted prompt (recorded per terminal by the
    ///   hooks). When several terminals resume the SAME session they all append to one file and each
    ///   grows its own branch, so this is what tells us which branch belongs to this terminal.
    static func parse(path: String, cwd: String = "", limit: Int = 120,
                      ownPrompt: String = "") -> ConvResult {
        var info = ConvInfo()
        guard let text = tail(path) else { return ConvResult(messages: [], info: info) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var msgs: [ConvMsg] = []
        var toolIndex: [String: Int] = [:]      // tool_use / call id → index in msgs

        let records: [[String: Any]] = lines.compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        // A Claude session is a TREE, not a list: rewinding or editing a prompt starts a new branch
        // and the old one stays in the file. Rendering the file linearly interleaves abandoned
        // attempts with the real conversation, so follow only the active branch.
        let active = activePath(records, ownPrompt: ownPrompt, &info)

        for obj in records {
            if obj["payload"] != nil {
                parseCodex(obj, into: &msgs, toolIndex: &toolIndex)
            } else {
                if let active {
                    // Keep subagent (sidechain) records regardless — they hang off their own chain.
                    let uuid = obj["uuid"] as? String
                    let sidechain = (obj["isSidechain"] as? Bool) ?? false
                    if !sidechain, let uuid, !active.contains(uuid) { continue }
                }
                parseClaude(obj, into: &msgs, toolIndex: &toolIndex, cwd: cwd)
                collectInfo(obj, into: &info)
            }
        }
        // A tool call that never got a result is either still running or waiting for approval —
        // that's what drives the live spinner and the "needs you" card.
        for i in msgs.indices where msgs[i].kind == "tool" && msgs[i].ok == nil && msgs[i].output == nil {
            msgs[i].pending = true
        }
        if let last = msgs.last(where: { $0.pending }) {
            info.pendingTool = last.tool
            info.pendingText = last.text
        }
        let out = msgs.count > limit ? Array(msgs.suffix(limit)) : msgs
        return ConvResult(messages: out, info: info)
    }

    /// The set of record uuids on the session's *active* branch, walking `parentUuid` back from the
    /// current leaf. Claude marks the live tip with a `last-prompt` record carrying `leafUuid`;
    /// without one, the newest record is the tip. Returns nil when the file has no tree at all
    /// (nothing to filter), and fills in how many branches the session has.
    private static func activePath(_ records: [[String: Any]], ownPrompt: String,
                                   _ info: inout ConvInfo) -> Set<String>? {
        var parent: [String: String] = [:]
        var children: [String: [String]] = [:]     // in file order ⇒ last child is the newest
        var byUuid: [String: [String: Any]] = [:]
        var order: [String] = []
        var leaf: String?

        for r in records {
            if (r["type"] as? String) == "last-prompt", let l = r["leafUuid"] as? String { leaf = l }
            guard let u = r["uuid"] as? String else { continue }
            byUuid[u] = r
            order.append(u)
            if let p = r["parentUuid"] as? String {
                parent[u] = p
                children[p, default: []].append(u)
            }
        }
        guard !order.isEmpty else { return nil }
        let leaves = order.filter { children[$0] == nil }
        info.branches = children.values.filter { $0.count > 1 }.count

        var tip: String?
        // Preferred: the branch whose most recent user prompt is the one THIS terminal submitted.
        // Several terminals resuming one session share the file, and this is the only per-terminal
        // marker in it (the hooks record the prompt against the terminal that sent it).
        let want = normalized(ownPrompt)
        if !want.isEmpty {
            tip = leaves.reversed().first { l in
                guard let text = latestUserText(from: l, parent: parent, byUuid: byUuid) else { return false }
                return matches(normalized(text), want)
            }
        }
        if tip == nil {
            // Otherwise: `leafUuid` is the tip *as of the last prompt*, so replies made after it hang
            // below — descend to the current end of that branch before walking back, or the newest
            // messages get filtered out as if they belonged to another branch.
            tip = leaf.flatMap { byUuid[$0] != nil ? $0 : nil } ?? order.last
            var visited = Set<String>()
            while let u = tip, let kids = children[u], let next = kids.last, !visited.contains(u) {
                visited.insert(u)
                tip = next
            }
        }
        var path = Set<String>()
        while let u = tip, !path.contains(u) {
            path.insert(u)
            tip = parent[u]
        }
        return path.isEmpty ? nil : path
    }

    /// Text of the most recent real user prompt on a branch (skipping tool results and subagents).
    private static func latestUserText(from leafUuid: String, parent: [String: String],
                                       byUuid: [String: [String: Any]]) -> String? {
        var u: String? = leafUuid
        var seen = Set<String>()
        while let cur = u, !seen.contains(cur) {
            seen.insert(cur)
            if let r = byUuid[cur], (r["type"] as? String) == "user",
               (r["isSidechain"] as? Bool) != true,
               let msg = r["message"] as? [String: Any] {
                if let s = msg["content"] as? String, !trim(s).isEmpty { return s }
                if let blocks = msg["content"] as? [[String: Any]] {
                    for b in blocks where (b["type"] as? String) == "text" {
                        if let t = b["text"] as? String, !trim(t).isEmpty { return t }
                    }
                }
            }
            u = parent[cur]
        }
        return nil
    }

    /// Whitespace-collapsed comparison: the stored prompt has newlines flattened to spaces.
    private static func normalized(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Either side may be truncated, so a long common prefix counts as a match.
    private static func matches(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let n = min(a.count, b.count)
        guard n >= 12 else { return false }
        return a.prefix(n) == b.prefix(n)
    }

    /// Session facts that live in their own transcript records (Claude): the model in use, the
    /// current permission mode, and how much of the context window the last turn occupied.
    private static func collectInfo(_ obj: [String: Any], into info: inout ConvInfo) {
        switch obj["type"] as? String {
        case "permission-mode":
            if let m = obj["permissionMode"] as? String { info.permissionMode = m }
        case "assistant":
            guard let msg = obj["message"] as? [String: Any] else { return }
            if let m = msg["model"] as? String { info.model = m }
            if let u = msg["usage"] as? [String: Any] {
                let used = ((u["input_tokens"] as? Int) ?? 0)
                    + ((u["cache_read_input_tokens"] as? Int) ?? 0)
                    + ((u["cache_creation_input_tokens"] as? Int) ?? 0)
                if used > 0 { info.contextTokens = used }   // last turn wins — that's "how full it is now"
            }
        default:
            return
        }
    }

    /// Context window for the model in use. The transcript never states it, so: assume the standard
    /// 200k, and if a turn has already exceeded that the session must be a long-context variant.
    static func contextWindow(model: String?, used: Int) -> Int {
        let m = (model ?? "").lowercased()
        if m.contains("1m") || used > 200_000 { return 1_000_000 }
        return 200_000
    }

    /// Parse the numbered choices an agent prints when it needs a decision (Claude and Codex both
    /// use "1. Yes" style lists), so the web can render one button per option.
    /// A run of consecutive "N. label" lines, and whether the picker's cursor sits on one of them.
    private struct OptionRun { var hasCursor = false; var opts: [ConvOption] = []; var question: String? }

    static func options(fromScreen screen: String) -> (question: String?, options: [ConvOption]) {
        var runs: [OptionRun] = []
        var cur = OptionRun()
        var lastQuestion: String?

        for raw in screen.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }                       // blanks don't break a picker block
            // The cursor must be on THIS line for it to count — Claude's composer prompt is also
            // "❯", just with nothing after it, so "cursor anywhere on screen" matches every frame.
            let cursor = line.hasPrefix("❯") || line.hasPrefix("›")
            let body = line.drop(while: { "❯›".contains($0) || $0 == " " })

            if let sep = body.firstIndex(where: { $0 == "." || $0 == ")" }) {
                let num = String(body[body.startIndex..<sep])
                let label = String(body[body.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
                if !num.isEmpty, num.count <= 2, num.allSatisfy({ $0.isNumber }),
                   !label.isEmpty, label.count < 120 {
                    if cur.opts.isEmpty { cur.question = lastQuestion }
                    if !cur.opts.contains(where: { $0.n == num }) {
                        cur.opts.append(ConvOption(n: num, label: clip(label, 90)))
                    }
                    if cursor { cur.hasCursor = true }
                    continue
                }
            }
            if !cur.opts.isEmpty { runs.append(cur); cur = OptionRun() }   // any other line ends the run
            if line.hasSuffix("?") && line.count > 8 { lastQuestion = line }
        }
        if !cur.opts.isEmpty { runs.append(cur) }

        // The live picker is the LAST block that has a highlighted choice. A numbered list the agent
        // merely printed has no cursor on it, so it can never be mistaken for a prompt.
        guard let picker = runs.last(where: { $0.hasCursor && $0.opts.count >= 2 }) else { return (nil, []) }
        return (picker.question, picker.opts)
    }

    // MARK: - Claude Code

    private static func parseClaude(_ obj: [String: Any], into msgs: inout [ConvMsg],
                                    toolIndex: inout [String: Int], cwd: String = "") {
        let type = obj["type"] as? String
        guard type == "user" || type == "assistant" else { return }
        guard let message = obj["message"] as? [String: Any] else { return }
        let role = (message["role"] as? String) ?? type ?? "user"
        let ts = obj["timestamp"] as? String
        let sub = (obj["isSidechain"] as? Bool) ?? false

        if let s = message["content"] as? String {
            append(&msgs, ConvMsg(role: role, kind: "text", text: trim(s), tool: nil, cat: nil,
                                  detail: nil, output: nil, ok: nil, ts: ts, sub: sub))
            return
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                if let t = b["text"] as? String, !trim(t).isEmpty {
                    append(&msgs, ConvMsg(role: role, kind: "text", text: trim(t), tool: nil, cat: nil,
                                          detail: nil, output: nil, ok: nil, ts: ts, sub: sub))
                }
            case "thinking":
                if let t = b["thinking"] as? String, !trim(t).isEmpty {
                    append(&msgs, ConvMsg(role: "assistant", kind: "thinking", text: trim(t), tool: nil,
                                          cat: nil, detail: nil, output: nil, ok: nil, ts: ts, sub: sub))
                }
            case "tool_use":
                let name = (b["name"] as? String) ?? "tool"
                let input = (b["input"] as? [String: Any]) ?? [:]
                let edits = editPairs(tool: name, input: input)
                var m = ConvMsg(role: "tool", kind: "tool",
                                text: rel(summary(tool: name, input: input), cwd),
                                tool: name, cat: category(name),
                                detail: edits == nil ? detail(input, tool: name) : nil,   // a diff beats raw JSON
                                output: nil, ok: nil, ts: ts, sub: sub,
                                file: rel(input["file_path"] as? String ?? "", cwd), edits: edits)
                m.text = m.text.isEmpty ? name : m.text
                msgs.append(m)
                if let id = b["id"] as? String { toolIndex[id] = msgs.count - 1 }
            case "tool_result":
                guard let id = b["tool_use_id"] as? String, let i = toolIndex[id] else { continue }
                msgs[i].output = clip(flatten(b["content"]), 1200)
                msgs[i].ok = !((b["is_error"] as? Bool) ?? false)
            default:
                continue
            }
        }
    }

    // MARK: - Codex

    private static func parseCodex(_ obj: [String: Any], into msgs: inout [ConvMsg],
                                   toolIndex: inout [String: Int]) {
        guard let p = obj["payload"] as? [String: Any] else { return }
        let ts = obj["timestamp"] as? String
        let outer = obj["type"] as? String
        switch p["type"] as? String {
        case "user_message":
            if let t = p["message"] as? String, !trim(t).isEmpty {
                append(&msgs, ConvMsg(role: "user", kind: "text", text: trim(t), tool: nil, cat: nil,
                                      detail: nil, output: nil, ok: nil, ts: ts, sub: false))
            }
        case "agent_message":
            // Both event_msg and response_item carry these; keep one copy (event_msg is the clean one).
            guard outer == "event_msg", let t = p["message"] as? String, !trim(t).isEmpty else { return }
            append(&msgs, ConvMsg(role: "assistant", kind: "text", text: trim(t), tool: nil, cat: nil,
                                  detail: nil, output: nil, ok: nil, ts: ts, sub: false))
        case "agent_reasoning":
            if let t = (p["text"] as? String) ?? (p["reasoning"] as? String), !trim(t).isEmpty {
                append(&msgs, ConvMsg(role: "assistant", kind: "thinking", text: trim(t), tool: nil,
                                      cat: nil, detail: nil, output: nil, ok: nil, ts: ts, sub: false))
            }
        case "function_call", "custom_tool_call":
            let name = (p["name"] as? String) ?? "tool"
            let args = p["arguments"] ?? p["input"]
            var input: [String: Any] = [:]
            if let s = args as? String, let d = s.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { input = o }
            else if let o = args as? [String: Any] { input = o }
            // apply_patch carries a ready-made patch as a plain string — keep it for diff rendering.
            let raw = args as? String
            let isPatch = name == "apply_patch" && (raw?.contains("*** ") == true || raw?.contains("@@") == true)
            let sum = summary(tool: name, input: input)
            let m = ConvMsg(role: "tool", kind: "tool",
                            text: isPatch ? patchTitle(raw ?? "") : (sum.isEmpty ? name : sum), tool: name,
                            cat: category(name),
                            detail: (isPatch || !input.isEmpty) ? (input.isEmpty ? nil : detail(input))
                                                                : clip(flatten(args), 600),
                            output: nil, ok: nil, ts: ts, sub: false,
                            patch: isPatch ? clip(raw ?? "", 8000) : nil)
            msgs.append(m)
            if let id = (p["call_id"] as? String) ?? (p["id"] as? String) { toolIndex[id] = msgs.count - 1 }
        case "function_call_output", "custom_tool_call_output":
            guard let id = (p["call_id"] as? String) ?? (p["id"] as? String), let i = toolIndex[id] else { return }
            msgs[i].output = clip(flatten(p["output"] ?? p["result"]), 1200)
            msgs[i].ok = true
        default:
            return
        }
    }

    // MARK: - Helpers

    /// Read only the last `tailBytes` of the file, dropping a partial first line.
    private static func tail(_ path: String) -> String? {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let start = size > tailBytes ? size - tailBytes : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), var s = String(data: data, encoding: .utf8) else { return nil }
        if start > 0, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        return s
    }

    /// Merge consecutive same-role text so a streamed reply reads as one message.
    private static func append(_ msgs: inout [ConvMsg], _ m: ConvMsg) {
        if let last = msgs.last, last.role == m.role, last.kind == m.kind, m.kind != "tool",
           last.sub == m.sub, m.text.count < 4000 {
            msgs[msgs.count - 1].text += "\n" + m.text
            return
        }
        var m = m
        m.text = clip(m.text, 6000)
        msgs.append(m)
    }

    /// Title for a Codex patch: the file it updates (its header line), so the card isn't just
    /// "apply_patch".
    private static func patchTitle(_ patch: String) -> String {
        for line in patch.split(separator: "\n") where line.hasPrefix("*** ") {
            if let colon = line.firstIndex(of: ":") {
                return clip(trim(String(line[line.index(after: colon)...])), 200)
            }
        }
        return "apply_patch"
    }

    /// Before/after pairs for the edit tools, so the web view can show a real diff instead of a JSON
    /// dump: Edit (one pair), MultiEdit (one per edit), Write (all-new content).
    private static func editPairs(tool: String, input: [String: Any]) -> [ConvEdit]? {
        switch tool {
        case "Edit":
            guard let o = input["old_string"] as? String, let n = input["new_string"] as? String else { return nil }
            return [ConvEdit(old: clip(o, 6000), new: clip(n, 6000))]
        case "MultiEdit":
            guard let arr = input["edits"] as? [[String: Any]] else { return nil }
            let pairs = arr.compactMap { e -> ConvEdit? in
                guard let o = e["old_string"] as? String, let n = e["new_string"] as? String else { return nil }
                return ConvEdit(old: clip(o, 4000), new: clip(n, 4000))
            }
            return pairs.isEmpty ? nil : pairs
        case "Write":
            guard let c = input["content"] as? String else { return nil }
            return [ConvEdit(old: "", new: clip(c, 6000))]
        default:
            return nil
        }
    }

    /// Tool families (mirrors the grouping Happy uses) — drives the icon in the web view.
    private static func category(_ name: String) -> String {
        switch name {
        case "Bash", "CodexBash", "GeminiBash", "shell", "execute", "local_shell", "exec_command":
            return "terminal"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "CodexPatch", "apply_patch", "write_file":
            return "edit"
        case "Read", "NotebookRead", "LS", "read", "read_file", "view_image": return "read"
        case "Grep", "Glob", "search", "WebSearch", "file_search": return "search"
        case "WebFetch", "fetch", "web_search": return "web"
        case "Task", "Agent", "spawn_agent", "wait_agent", "list_agents", "send_agent_message":
            return "task"
        default: return "other"
        }
    }

    /// A one-line "what this call does" label, e.g. the command for Bash/exec_command or the file
    /// for Read. Key names differ between Claude and Codex, so several are tried in priority order.
    private static func summary(tool: String, input: [String: Any]) -> String {
        // The agent's own one-line `description` reads better than a wrapped shell command on a
        // phone (the full command is still there when you expand the card).
        if let d = input["description"] as? String, !d.isEmpty { return clip(trim(d), 200) }
        for key in ["command", "cmd", "file_path", "path", "pattern", "url",
                    "task_name", "prompt", "query", "path_prefix"] {
            if let v = input[key] as? String, !v.isEmpty { return clip(trim(v), 200) }
        }
        return ""
    }

    /// Show paths relative to the project so a narrow card isn't all home-directory prefix.
    private static func rel(_ path: String, _ cwd: String) -> String {
        guard !path.isEmpty else { return "" }
        if !cwd.isEmpty, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        let home = FV.home.path
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }

    /// Raw input JSON. Kept generous for the tools whose payload IS the content (a todo list, a
    /// plan, a question) — the web renders those specially and needs the whole thing.
    private static func detail(_ input: [String: Any], tool: String = "") -> String? {
        guard !input.isEmpty,
              let d = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        let rich = ["TodoWrite", "ExitPlanMode", "AskUserQuestion", "Task"].contains(tool)
        return clip(s, rich ? 8000 : 800)
    }

    /// Tool results arrive as a string, or as blocks like [{type:"text", text:"…"}].
    private static func flatten(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let blocks = any as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String ?? $0["content"] as? String }
                .joined(separator: "\n")
        }
        if let o = any, let d = try? JSONSerialization.data(withJSONObject: o),
           let s = String(data: d, encoding: .utf8) { return s }
        return ""
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}
