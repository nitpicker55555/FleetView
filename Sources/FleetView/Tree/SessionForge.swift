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

    static let skipPermissionsFlag = "--dangerously-skip-permissions"

    /// `claude --resume <sid>` plus flags carried over from the source terminal, so a fork behaves
    /// like its parent (`--dangerously-skip-permissions`, model choice, …).
    ///
    /// `skipPermissions` forces that flag on regardless of what the source ran with. Opening a tree
    /// node or a search hit resumes a conversation that already happened; a terminal that appears on
    /// the board and then stops on its first tool call — while you are still looking at the tree —
    /// is not what the drop meant.
    ///
    /// `cwd` matters: Claude resolves `--resume <sid>` against the *current directory's* project
    /// slug, so a session recorded elsewhere (an agent started after `cd`) is invisible unless we
    /// cd back first — otherwise the fork opens with "No conversation found".
    static func resumeCommand(sessionId: String, inheritedFlags: [String],
                              forkSession: Bool = false, skipPermissions: Bool = false,
                              cwd: String? = nil) -> String {
        var parts = ["claude", "--resume", sessionId]
        if forkSession { parts.append("--fork-session") }
        parts.append(contentsOf: skipPermissions ? forcingSkipPermissions(inheritedFlags)
                                                 : inheritedFlags)
        let cmd = parts.joined(separator: " ")
        guard let cwd, !cwd.isEmpty else { return cmd }
        return "cd \(shellQuote(cwd)) && \(cmd)"
    }

    /// Append the flag exactly once, dropping any inherited `--permission-mode`. The CLI accepts
    /// both together but does not say which wins; inheriting `--permission-mode plan` from the
    /// source terminal must not be able to quietly re-arm the prompts this is here to remove.
    private static func forcingSkipPermissions(_ flags: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < flags.count {
            defer { i += 1 }
            if flags[i] == "--permission-mode" { i += 1; continue }   // skip its value too
            if flags[i] == skipPermissionsFlag { continue }
            out.append(flags[i])
        }
        out.append(skipPermissionsFlag)
        return out
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
        let start = size > window ? size - window : 0
        try? h.seek(toOffset: start)
        // Drop the partial first line as BYTES before decoding: the window starts at an arbitrary
        // offset, and one split multi-byte character makes String(data:encoding:) return nil for
        // the whole block — which here would silently lose the cwd and open the fork in the wrong
        // directory.
        guard var data = try? h.readToEnd() else { return nil }
        if start > 0, let nl = data.firstIndex(of: 0x0A) {
            data = data.subdata(in: data.index(after: nl)..<data.endIndex)
        }
        // Split on newlines and decode a line at a time. Decoding the window as one string threw the
        // whole thing away for a single bad byte, and the file may be *being written* as we read: the
        // last line is then a partial record, often ending mid-character. That is the same failure
        // the leading-partial-line fix was about, at the other end of the window — and here it does
        // not announce itself, it just reports that the session has no folder.
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard line.first == UInt8(ascii: "{"),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// Claude's project-directory name for a path: every character that is not an ASCII letter or
    /// digit becomes `-`. It is what makes the mapping one-way — `datagen_vision2web` and a real
    /// `datagen-vision2web` produce the same slug — and it is exactly the check for "would resuming
    /// from here look in this project directory".
    static func slugify(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The directory to resume a project's sessions from.
    ///
    /// It has to be a folder whose slug IS this project directory: `--resume <sid>` looks the
    /// session up under the slug of the *current* folder, so anywhere else answers "No conversation
    /// found" however truthful it is. A transcript's own `cwd` is not automatically that folder —
    /// `cwd` is per record and follows the agent, so a subagent started after a `cd`, or a session
    /// that moved during its run, records a subdirectory while its file stays filed under the slug
    /// it started in. On this machine that is 52 of 70 recorded cwds, so it is the normal case, not
    /// the exception.
    ///
    /// Hence: decode the slug back into a real path, resolved against the filesystem because the
    /// encoding is not reversible on its own.
    static func projectCwd(projectDir: URL) -> String? {
        if let p = cwdFromSlug(projectDir.lastPathComponent) { return p }
        // Nothing on disk answers to that slug any more — the folder was renamed, moved or deleted.
        // Nothing will make `--resume` find these sessions, but opening the terminal somewhere the
        // work actually happened still beats refusing to open one at all.
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { mtime($0) > mtime($1) }     // newest first — most likely to still be intact
        for f in files.prefix(8) {
            if let cwd = sessionCwd(transcriptPath: f.path) { return cwd }
        }
        return nil
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Turn `-Users-puzhen-PycharmProjects-datagen-vision2web` back into a real path.
    ///
    /// The slug cannot be decoded by rule — every `/`, `_` and `.` arrives as the same `-` — so it is
    /// matched against the filesystem one level at a time: a child directory belongs at this
    /// position if its own slug sits at the front of what is left. Longest match first, so
    /// `datagen-vision2web` wins over a `datagen` that also exists, with backtracking when the long
    /// one leads nowhere. Nil rather than a plausible guess: a wrong directory does not fail, it
    /// opens the fork on "No conversation found", which is much harder to work out from.
    static func cwdFromSlug(_ slug: String) -> String? {
        guard slug.hasPrefix("-") else { return nil }
        let fm = FileManager.default
        func walk(_ prefix: String, _ rest: Substring) -> String? {
            if rest.isEmpty { return prefix }
            let names = ((try? fm.contentsOfDirectory(atPath: prefix.isEmpty ? "/" : prefix)) ?? [])
                .sorted { $0.count > $1.count }
            for name in names {
                let s = slugify(name)
                guard rest.hasPrefix(s) else { continue }
                let after = rest.dropFirst(s.count)
                guard after.isEmpty || after.hasPrefix("-") else { continue }   // component boundary
                let path = prefix + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                if let hit = walk(path, after.isEmpty ? after : after.dropFirst()) { return hit }
            }
            return nil
        }
        return walk("", slug.dropFirst())
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
