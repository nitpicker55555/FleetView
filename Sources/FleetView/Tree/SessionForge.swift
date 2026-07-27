import Foundation

/// Turns a tree node into something a terminal can open — a Swift port of treeflow's
/// `write_synthetic_session` + `emit_resume`.
///
/// Fork semantics: the ORIGINAL session file is never touched. Either the node is "native"
/// (some existing session's leaf already resolves there → plain `--resume <that sid>`), or we
/// synthesize a fresh `<new-sid>.jsonl` containing the node's ancestry plus its own reply chain,
/// pinned with a `last-prompt` record — Claude resumes exactly at that point in a new session.
enum SessionForge {

    struct ForkResult {
        let sessionId: String
        let wroteFile: URL?       // nil ⇒ native resume, no file written
        let chainLength: Int
    }

    enum ForgeError: LocalizedError {
        case nodeNotFound
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .nodeNotFound: return "node not found in project directory"
            case .writeFailed(let m): return "could not write forked session: \(m)"
            }
        }
    }

    // MARK: - Fork

    /// Resolve a node into a resumable session id. Runs file IO — call off the main thread.
    static func fork(projectDir: URL, targetUuid: String, nativeSessionId: String?) throws -> ForkResult {
        if let sid = nativeSessionId {
            return ForkResult(sessionId: sid, wroteFile: nil, chainLength: 0)
        }

        let files = ((try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Slim graph (cache-warm via SessionTreeBuilder) with file provenance: uuid → first file.
        var slim: [String: SlimRecord] = [:]
        var fileOf: [String: URL] = [:]
        for f in files {
            let (records, _, _) = SessionTreeBuilder.parseFile(f)
            for r in records where slim[r.uuid] == nil {
                slim[r.uuid] = r
                fileOf[r.uuid] = f
            }
        }
        guard slim[targetUuid] != nil else { throw ForgeError.nodeNotFound }

        // Back chain: target + all ancestors, oldest first.
        var backChain: [String] = []
        var cur: String? = targetUuid
        var seen = Set<String>()
        while let c = cur, !seen.contains(c), let r = slim[c] {
            seen.insert(c)
            backChain.append(c)
            cur = r.parent
        }
        backChain.reverse()

        // Forward chain: the target's own reply events (assistant/tool records), BFS stopping at
        // the next user prompt — without this the fork would resume with the prompt unanswered.
        var childrenIndex: [String: [String]] = [:]
        for (u, r) in slim {
            if let p = r.parent { childrenIndex[p, default: []].append(u) }
        }
        var forward: [String] = []
        var visited: Set<String> = [targetUuid]
        var queue = [targetUuid]
        while !queue.isEmpty {
            let u = queue.removeFirst()
            for child in childrenIndex[u] ?? [] where !visited.contains(child) {
                guard let r = slim[child], !r.isPrompt else { continue }
                visited.insert(child)
                forward.append(child)
                queue.append(child)
            }
        }
        forward.sort { (slim[$0]?.ts ?? "") < (slim[$1]?.ts ?? "") }

        let orderedUuids = backChain + forward
        let leafUuid = forward.last ?? targetUuid

        // Pull the raw lines for exactly those records, touching only the files that contain them.
        var neededByFile: [URL: Set<String>] = [:]
        for u in orderedUuids {
            if let f = fileOf[u] { neededByFile[f, default: []].insert(u) }
        }
        var rawLine: [String: String] = [:]
        for (f, needed) in neededByFile {
            guard let data = try? Data(contentsOf: f),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var remaining = needed
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if remaining.isEmpty { break }
                guard line.first == "{", let d = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let u = obj["uuid"] as? String, remaining.contains(u) else { continue }
                rawLine[u] = String(line)
                remaining.remove(u)
            }
        }

        // last-prompt pin (same fields treeflow writes).
        let targetText = slim[targetUuid]?.text ?? ""
        let newSid = UUID().uuidString.lowercased()
        let pin: [String: Any] = ["type": "last-prompt", "lastPrompt": targetText,
                                  "leafUuid": leafUuid, "sessionId": newSid]
        guard let pinData = try? JSONSerialization.data(withJSONObject: pin),
              let pinLine = String(data: pinData, encoding: .utf8) else {
            throw ForgeError.writeFailed("could not encode last-prompt record")
        }

        var out = orderedUuids.compactMap { rawLine[$0] }
        let chainLength = out.count
        out.append(pinLine)
        let dest = projectDir.appendingPathComponent("\(newSid).jsonl")
        do {
            try (out.joined(separator: "\n") + "\n").write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            throw ForgeError.writeFailed(error.localizedDescription)
        }
        return ForkResult(sessionId: newSid, wroteFile: dest, chainLength: chainLength)
    }

    // MARK: - Resume command

    /// `claude --resume <sid>` plus flags carried over from the source terminal, so a fork behaves
    /// like its parent (`--dangerously-skip-permissions`, model choice, …).
    ///
    /// `cwd` matters: Claude resolves `--resume <sid>` against the *current directory's* project
    /// slug, so a session recorded elsewhere (an agent started after `cd`) is invisible unless we
    /// cd back first — otherwise the fork opens with "No conversation found".
    static func resumeCommand(sessionId: String, inheritedFlags: [String],
                              forkSession: Bool = false, cwd: String? = nil) -> String {
        var parts = ["claude", "--resume", sessionId]
        if forkSession { parts.append("--fork-session") }
        parts.append(contentsOf: inheritedFlags)
        let cmd = parts.joined(separator: " ")
        guard let cwd, !cwd.isEmpty else { return cmd }
        return "cd \(shellQuote(cwd)) && \(cmd)"
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The directory the session was recorded in (Claude stamps `cwd` on every record). Read from
    /// the tail so a 40 MB transcript costs nothing.
    static func sessionCwd(transcriptPath: String) -> String? {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath)) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let window: UInt64 = 400_000
        try? h.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.first == "{", let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// Flags the source terminal's live claude process was started with, filtered to a safe
    /// whitelist (never carry --resume/--continue/-p and their values).
    /// Shells out to tmux/pgrep/ps — quick, but keep it off the main thread.
    static func inheritedFlags(tmuxPath: String, tmuxSocket: String, sessionName: String) -> [String] {
        guard let panePid = run(tmuxPath, ["-L", tmuxSocket, "list-panes", "-t", sessionName,
                                           "-F", "#{pane_pid}"])?
            .split(separator: "\n").first.map(String.init) else { return [] }

        // Walk down the process tree from the pane's shell looking for the claude CLI.
        var frontier = [panePid], args: [String]?; args = nil
        for _ in 0..<3 {
            var next: [String] = []
            for pid in frontier {
                guard let kids = run("/usr/bin/pgrep", ["-P", pid]) else { continue }
                for kid in kids.split(separator: "\n").map(String.init) {
                    let a = run("/bin/ps", ["-p", kid, "-o", "args="]) ?? ""
                    let argv = a.split(separator: " ").map(String.init)
                    if argv.contains(where: { $0 == "claude" || $0.hasSuffix("/claude") }) {
                        args = argv
                    }
                    next.append(kid)
                }
            }
            if args != nil { break }
            frontier = next
            if frontier.isEmpty { break }
        }
        guard let argv = args else { return [] }

        let valueFlags: Set<String> = ["--model", "--permission-mode", "--effort", "--add-dir", "--agent"]
        let bareFlags: Set<String> = ["--dangerously-skip-permissions"]
        var flags: [String] = []
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if bareFlags.contains(a) {
                flags.append(a)
            } else if valueFlags.contains(a), i + 1 < argv.count {
                flags.append(a); flags.append(argv[i + 1]); i += 1
            }
            i += 1
        }
        return flags
    }

    private static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
