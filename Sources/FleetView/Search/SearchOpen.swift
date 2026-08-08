import Foundation

/// Turns a search hit into a command that opens that conversation *at that point* — treeflow
/// semantics, including branches that were later abandoned. Opening an old node is the whole
/// reason to search: finding the text is only half of it.
///
/// The two backends are resolved differently, for a concrete reason. FleetView already contains a
/// Swift port of treeflow's Claude forking (`SessionForge`), so Claude hits are resolved in-process
/// and open instantly. Nothing equivalent exists for Codex — rollouts are stored by date rather
/// than by project and branch via `forked_from_id` — but the `treeflow` CLI implements it already,
/// so Codex hits shell out to it rather than growing a second copy of that logic here.
enum SearchOpen {

    /// Everything a terminal needs to land on the hit.
    struct Plan {
        let command: String       // typed into a fresh shell
        let cwd: String           // where that terminal should start
        let label: String         // short terminal name
        let synthesized: Bool     // a fork file was written (vs. a plain resume)
        let detail: String        // one line for the log
    }

    enum OpenError: LocalizedError {
        case notClaudeProject(String)
        case treeflowMissing
        case treeflow(String)
        case noCwd(String)

        var errorDescription: String? {
            switch self {
            case .notClaudeProject(let p): return "not inside ~/.claude/projects: \(p)"
            case .treeflowMissing:
                // Say the command, not just the name: this is the only thing standing between the
                // user and a Codex conversation opening, and it is one line.
                return "打开 Codex 会话需要 treeflow：\n"
                     + "pip3 install 'git+https://github.com/nitpicker55555/Agent-Treeflow.git'"
            case .treeflow(let m): return "treeflow: \(m)"
            // Name the file: every remaining way to reach this is a property of one transcript
            // (deleted, or never recorded a cwd anywhere), and without it the report is unactionable.
            case .noCwd(let p): return "could not determine the session's working directory\n\(p)"
            }
        }
    }

    // MARK: - Entry point

    /// Resolve a hit. Does file IO and may run a subprocess — call off the main thread.
    static func plan(for hit: SearchIndex.Hit, inheritedFlags: [String] = []) throws -> Plan {
        switch hit.src {
        case .claude: return try planClaude(hit, inheritedFlags: inheritedFlags)
        case .codex: return try planCodex(hit)
        }
    }

    /// A short terminal name from the hit's text, so the card is recognisable on the board.
    private static func label(_ hit: SearchIndex.Hit) -> String {
        let flat = hit.body.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "⌕ " + String(flat.prefix(12))
    }

    // MARK: - Claude

    private static func planClaude(_ hit: SearchIndex.Hit, inheritedFlags: [String]) throws -> Plan {
        guard let projectDir = claudeProjectDir(for: hit.path) else {
            throw OpenError.notClaudeProject(hit.path)
        }
        let anchor = anchorUuid(for: hit)
        // Ask first whether some session already resumes to exactly this node: stock
        // `claude --resume <sid>` then lands here and nothing has to be written. This matters more
        // than it looks — a synthetic fork copies the whole ancestor chain, which runs 9–14 MB on
        // this machine, and it also makes re-opening the same hit free, because the fork written
        // the first time is itself natively reachable afterwards.
        let native = SessionTreeBuilder.build(projectDir: projectDir, boundSessionId: nil)
            .nodes[anchor]?.nativeSessionId
        let fork = try SessionForge.fork(projectDir: projectDir, targetUuid: anchor,
                                         nativeSessionId: native)
        // Where to open the terminal. Two things have to hold, and only one of them was checked:
        //
        // 1. There has to *be* an answer. The index records the cwd it saw, but an incremental pass
        //    over pure tool traffic (Claude) or anything past line 0 (Codex) sees none — and that
        //    emptiness used to be written over the folder already stored. So a missing index value
        //    is normal, not a corruption, and the transcript is read directly instead.
        // 2. It has to be the folder this file is *filed under*. `--resume <sid>` looks the session
        //    up beneath the slug of the current directory, so a truthful-but-different cwd — the
        //    subdirectory a subagent was started in, say — opens the fork on "No conversation
        //    found" without ever mentioning the directory. Recorded cwds fail that test far more
        //    often than they pass it, so the slug is decoded when they disagree.
        let recorded = hit.project.isEmpty
            ? SessionForge.sessionCwd(transcriptPath: hit.path)
            : hit.project
        let filedUnder = projectDir.lastPathComponent
        let cwd = (recorded.map { SessionForge.slugify($0) == filedUnder } == true)
            ? recorded!
            : (SessionForge.projectCwd(projectDir: projectDir) ?? recorded ?? "")
        guard !cwd.isEmpty else { throw OpenError.noCwd(hit.path) }
        // A fork duplicates an existing conversation, so indexing it would show every prompt twice.
        // Registering it seeds the index's byte offset past the copied prefix — work done in the
        // resumed session *after* this point is new, and is indexed normally. Registered with the
        // resolved `cwd` rather than `hit.project`: a fork inherits its parent's folder, and writing
        // the empty string this hit may have carried would hand the same un-openable state to the
        // next drag — which is how one un-openable hit used to breed more of them.
        if let written = fork.wroteFile {
            SearchIndex.excludeCopiedPrefix(path: written.path, src: .claude,
                                            session: fork.sessionId, project: cwd)
        }
        let command = SessionForge.resumeCommand(sessionId: fork.sessionId,
                                                 inheritedFlags: inheritedFlags,
                                                 skipPermissions: true, cwd: cwd)
        return Plan(command: command, cwd: cwd, label: label(hit),
                    synthesized: fork.wroteFile != nil,
                    detail: "claude node=\(anchor.prefix(8)) sid=\(fork.sessionId.prefix(8)) " +
                            "chain=\(fork.chainLength)")
    }

    /// The uuid to fork at. A prompt hit is already the anchor; a reply hit has to walk up to the
    /// prompt whose turn it belongs to, which is where treeflow anchors a node.
    private static func anchorUuid(for hit: SearchIndex.Hit) -> String {
        guard hit.role == .assistant else { return hit.node }
        let (records, _, _) = SessionTreeBuilder.parseFile(URL(fileURLWithPath: hit.path))
        var byUuid: [String: SlimRecord] = [:]
        for r in records { if byUuid[r.uuid] == nil { byUuid[r.uuid] = r } }

        var cur: String? = hit.node
        var seen = Set<String>()
        while let u = cur, !seen.contains(u), let r = byUuid[u] {
            seen.insert(u)
            if r.isPrompt { return u }
            cur = r.parent
        }
        // No prompt above it in this file (a chain that crosses files, or a subagent transcript):
        // forking at the record itself still lands on the right conversation.
        return hit.node
    }

    /// `~/.claude/projects/<slug>/…` → the `<slug>` directory, whatever layout the file is in
    /// (`<sid>.jsonl`, `<sid>/*.jsonl`, or `<sid>/subagents/agent-*.jsonl`).
    private static func claudeProjectDir(for path: String) -> URL? {
        let root = FV.claudeProjectsDir.standardizedFileURL.path
        var dir = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
        while dir.path.hasPrefix(root + "/") {
            if dir.deletingLastPathComponent().path == root { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Codex

    private static func planCodex(_ hit: SearchIndex.Hit) throws -> Plan {
        // A rollout's cwd is on its `session_meta` record — the very first line — so every
        // incremental index pass after the first one starts past it and learns nothing. Reading the
        // head here is the same fallback the Claude side gets from reading the tail, and without it
        // a Codex hit in a session that was still being written when it was first indexed could
        // never be opened at all.
        let cwd = hit.project.isEmpty ? (CodexSession.rolloutCwd(hit.path) ?? "") : hit.project
        guard !cwd.isEmpty else { throw OpenError.noCwd(hit.path) }
        return try planCodexNode(node: hit.node, cwd: cwd, label: label(hit))
    }

    /// Open a Codex node by its treeflow address (`<session-id>:<n>`).
    ///
    /// Split out from the search path because the session tree addresses nodes identically — see
    /// CodexTree, which numbers prompts the way treeflow does precisely so that a node dragged off
    /// the tree and a node dragged out of search results are the same string and open the same way.
    static func planCodexNode(node: String, cwd: String, label: String) throws -> Plan {
        guard let tool = treeflowPath() else { throw OpenError.treeflowMissing }
        // treeflow scopes Codex sessions by cwd and has no way to be told a session id directly,
        // so the project path is not optional here.
        let out = try run(tool, ["-p", cwd, "--codex", "resume", node, "--json"],
                          cwd: cwd)
        guard let data = out.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = obj["command"] as? String else {
            throw OpenError.treeflow(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let synthesized = (obj["synthesized"] as? Bool) ?? false
        let chain = (obj["chain_length"] as? Int) ?? 0
        let sid = (obj["session_id"] as? String) ?? ""
        // Same reasoning as the Claude side: treeflow wrote a copy of the rollout, and it must not
        // come back as a second set of hits.
        if synthesized, let file = obj["file"] as? String {
            // `cwd`, not `hit.project`: registering the copy with the empty string this hit may have
            // carried would hand the same un-openable state straight to the next drag.
            SearchIndex.excludeCopiedPrefix(path: file, src: .codex, session: sid, project: cwd)
        }
        return Plan(command: "cd \(shellQuote(cwd)) && \(command)",
                    cwd: cwd, label: label, synthesized: synthesized,
                    detail: "codex node=\(node) sid=\(sid.prefix(8)) chain=\(chain)")
    }

    /// treeflow usually installs to `~/.local/bin`, which `Tooling.find` reaches via the login
    /// shell but does not probe directly.
    static func treeflowPath() -> String? {
        let local = FV.home.appendingPathComponent(".local/bin/treeflow").path
        if FileManager.default.isExecutableFile(atPath: local) { return local }
        return Tooling.find("treeflow")
    }

    /// Is Codex opening available at all? Drives whether the UI offers the action.
    static var codexOpenAvailable: Bool { treeflowPath() != nil }

    private static func run(_ tool: String, _ args: [String], cwd: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { throw OpenError.treeflow(error.localizedDescription) }
        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
