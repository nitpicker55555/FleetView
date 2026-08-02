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
        case noCwd

        var errorDescription: String? {
            switch self {
            case .notClaudeProject(let p): return "not inside ~/.claude/projects: \(p)"
            case .treeflowMissing:
                // Say the command, not just the name: this is the only thing standing between the
                // user and a Codex conversation opening, and it is one line.
                return "打开 Codex 会话需要 treeflow：\n"
                     + "pip3 install 'git+https://github.com/nitpicker55555/Agent-Treeflow.git'"
            case .treeflow(let m): return "treeflow: \(m)"
            case .noCwd: return "could not determine the session's working directory"
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
        // A fork duplicates an existing conversation, so indexing it would show every prompt
        // twice. Registering it seeds the index's byte offset past the copied prefix — work done
        // in the resumed session *after* this point is new, and is indexed normally.
        if let written = fork.wroteFile {
            SearchIndex.excludeCopiedPrefix(path: written.path, src: .claude,
                                            session: fork.sessionId, project: hit.project)
        }
        // The index recorded the cwd the session ran in; fall back to reading it off the
        // transcript. `--resume` resolves against the *current* directory's project slug, so
        // opening in the wrong directory yields "No conversation found".
        let cwd = hit.project.isEmpty
            ? (SessionForge.sessionCwd(transcriptPath: hit.path) ?? "")
            : hit.project
        guard !cwd.isEmpty else { throw OpenError.noCwd }
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
        guard let tool = treeflowPath() else { throw OpenError.treeflowMissing }
        guard !hit.project.isEmpty else { throw OpenError.noCwd }
        // treeflow scopes Codex sessions by cwd and has no way to be told a session id directly,
        // so the project path is not optional here.
        let out = try run(tool, ["-p", hit.project, "--codex", "resume", hit.node, "--json"],
                          cwd: hit.project)
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
            SearchIndex.excludeCopiedPrefix(path: file, src: .codex,
                                            session: sid, project: hit.project)
        }
        return Plan(command: "cd \(shellQuote(hit.project)) && \(command)",
                    cwd: hit.project, label: label(hit), synthesized: synthesized,
                    detail: "codex node=\(hit.node) sid=\(sid.prefix(8)) chain=\(chain)")
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
