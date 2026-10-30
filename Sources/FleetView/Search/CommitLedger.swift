import Foundation
import SQLite3

/// Which agent call made which commit — read from the agents' own transcripts, so it covers every
/// card, any repository, and commits made before anything here was watching.
///
/// A commit does not say which card made it, and its output usually does not say which commit it
/// made either: agents commit with `-q` and read the result back with `git log`, so of 246 commit
/// calls over two weeks, not one printed `[branch sha]`. What every call does record is when it was
/// sent and when it was answered, and where git ran. A commit committed inside that span, in that
/// repository, is the call's — measured on the same two weeks, 95 calls landed on exactly one commit,
/// 7 on several (one command committing twice), and the rest on none (nothing to commit, a hook
/// refused it, or it was amended away since).
///
/// A duplicated card's transcript carries its parent's calls under the same ids (`--fork-session`
/// copies them, as do the forks SessionForge and treeflow write), so the same commit would be found
/// in both. A call belongs to the conversation that made it: the oldest file it is in.
///
/// Read incrementally by byte offset, like the search index, but on its own offsets and in a file of
/// its own (`commits.db`): it reads lines the index skips, and must not be able to disturb it.
enum CommitLedger {

    struct Call: Sendable, Hashable {
        /// The tool call's own id, which a fork copies — see above.
        let id: String
        /// The conversation it was made in; a subagent's call is its conversation's.
        let transcript: String
        let codex: Bool
        let start: Date
        /// When it was answered; nil while it has not been (or never was — interrupted).
        let end: Date?
        /// Where git ran, and that directory's repository ("" when it no longer exists).
        let dir: String
        let top: String
        /// The commit the output named, when it named one.
        let sha: String

        /// The span a commit made by this call was committed in. Two seconds either side: git stamps
        /// whole seconds, and the transcript stamps when the call was sent, a little before git ran.
        var window: ClosedRange<Date> {
            let last = end ?? start.addingTimeInterval(120)
            return start.addingTimeInterval(-2)...max(start, last).addingTimeInterval(2)
        }
    }

    /// Utility: the first pass reads every transcript, and nothing on screen waits on it.
    private static let queue = DispatchQueue(label: "fleetview.commit-ledger", qos: .utility)
    private static var handle: OpaquePointer?
    private static var running = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var dbURL: URL { FV.supportDir.appendingPathComponent("commits.db") }

    // MARK: - Store

    private static func open() -> OpaquePointer? {
        if let handle { return handle }
        FV.ensureSupportDir()
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else { return nil }
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS scanned(path TEXT PRIMARY KEY, done INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS call(
            id TEXT PRIMARY KEY,
            transcript TEXT NOT NULL,
            codex INTEGER NOT NULL,
            born REAL NOT NULL,        -- when the transcript file was created: the oldest wins
            t0 REAL NOT NULL,
            t1 REAL,
            dir TEXT NOT NULL,
            top TEXT NOT NULL,
            sha TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS call_top ON call(top, t0);
        CREATE INDEX IF NOT EXISTS call_transcript ON call(transcript);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        handle = db
        return db
    }

    // MARK: - Reading the transcripts

    /// Bring the ledger up to date with every transcript under `roots`. The first pass reads all of
    /// them (the lines it wants are found by byte search before any JSON is decoded); after that only
    /// what was appended. `done` runs on the ledger's queue.
    static func refresh(roots: [(url: URL, codex: Bool)], done: (() -> Void)? = nil) {
        queue.async {
            defer { done?() }
            guard !running, let db = open() else { return }
            running = true
            defer { running = false }
            scan(db, roots: roots)
        }
    }

    private struct Found {
        var calls: [Call] = []
        /// Claude answers a call on a later line, possibly in a later pass: (id, answered, sha).
        var answers: [(String, Date, String)] = []
        var consumed = 0
    }

    private static func scan(_ db: OpaquePointer, roots: [(url: URL, codex: Bool)]) {
        let started = Date()
        var seen: [String: Int] = [:]
        query(db, "SELECT path, done FROM scanned") { s in
            seen[text(s, 0)] = Int(sqlite3_column_int64(s, 1))
        }
        var jobs: [(url: URL, codex: Bool, from: Int)] = []
        for root in roots {
            let e = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: [.fileSizeKey])
            while let url = e?.nextObject() as? URL {
                guard url.pathExtension == "jsonl" else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let from = seen[url.path] ?? 0
                if size > from { jobs.append((url, root.codex, from)) }
            }
        }
        guard !jobs.isEmpty else { return }

        // Calls still waiting for their answer, per transcript, so a later pass can close them.
        var open: [String: Set<String>] = [:]
        query(db, "SELECT transcript, id FROM call WHERE t1 IS NULL AND codex = 0") { s in
            open[text(s, 0), default: []].insert(text(s, 1))
        }

        let lock = NSLock()
        var results = [Int: Found]()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let job = jobs[i]
            let r = job.codex ? readCodex(job.url, from: job.from)
                              : readClaude(job.url, from: job.from, open: open[conversation(of: job.url).path] ?? [])
            lock.lock(); results[i] = r; lock.unlock()
        }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var upsert: OpaquePointer?, answer: OpaquePointer?, mark: OpaquePointer?
        // A copy of a call (a fork's transcript) replaces the row only if its file is older.
        sqlite3_prepare_v2(db, """
            INSERT INTO call(id, transcript, codex, born, t0, t1, dir, top, sha) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET transcript=excluded.transcript, born=excluded.born,
                t0=excluded.t0, t1=COALESCE(excluded.t1, call.t1), dir=excluded.dir, top=excluded.top,
                sha=CASE WHEN excluded.sha != '' THEN excluded.sha ELSE call.sha END
            WHERE excluded.born < call.born
            """, -1, &upsert, nil)
        sqlite3_prepare_v2(db, """
            UPDATE call SET t1 = COALESCE(t1, ?), sha = CASE WHEN sha = '' THEN ? ELSE sha END WHERE id = ?
            """, -1, &answer, nil)
        sqlite3_prepare_v2(db, """
            INSERT INTO scanned(path, done) VALUES(?, ?) ON CONFLICT(path) DO UPDATE SET done = excluded.done
            """, -1, &mark, nil)
        var calls = 0
        for i in 0..<jobs.count {
            guard let r = results[i] else { continue }
            let job = jobs[i]
            let main = conversation(of: job.url)
            let born = ((try? FileManager.default.attributesOfItem(atPath: main.path))?[.creationDate] as? Date
                        ?? (try? FileManager.default.attributesOfItem(atPath: job.url.path))?[.creationDate] as? Date
                        ?? Date()).timeIntervalSince1970
            for c in r.calls {
                sqlite3_reset(upsert)
                bind(upsert, 1, c.id); bind(upsert, 2, main.path)
                sqlite3_bind_int(upsert, 3, c.codex ? 1 : 0)
                sqlite3_bind_double(upsert, 4, born)
                sqlite3_bind_double(upsert, 5, c.start.timeIntervalSince1970)
                if let e = c.end { sqlite3_bind_double(upsert, 6, e.timeIntervalSince1970) } else { sqlite3_bind_null(upsert, 6) }
                bind(upsert, 7, c.dir); bind(upsert, 8, c.top); bind(upsert, 9, c.sha)
                if sqlite3_step(upsert) == SQLITE_DONE { calls += 1 }
            }
            for (id, at, sha) in r.answers {
                sqlite3_reset(answer)
                sqlite3_bind_double(answer, 1, at.timeIntervalSince1970)
                bind(answer, 2, sha); bind(answer, 3, id)
                sqlite3_step(answer)
            }
            sqlite3_reset(mark)
            bind(mark, 1, job.url.path)
            sqlite3_bind_int64(mark, 2, Int64(r.consumed))
            sqlite3_step(mark)
        }
        sqlite3_finalize(upsert); sqlite3_finalize(answer); sqlite3_finalize(mark)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        FV.log(String(format: "commits: read %d transcripts, %d commit calls, in %.1fs",
                      jobs.count, calls, Date().timeIntervalSince(started)))
    }

    /// A subagent's transcript (`<sid>/subagents/agent-*.jsonl`) belongs to its conversation.
    static func conversation(of url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        guard dir.lastPathComponent == "subagents" else { return url }
        let sid = dir.deletingLastPathComponent()
        return sid.deletingLastPathComponent().appendingPathComponent(sid.lastPathComponent + ".jsonl")
    }

    /// Complete lines from `offset`, and where the last one ended. A line still being written is left
    /// for the next pass.
    private static func lines(_ url: URL, from offset: Int, _ body: (Data) -> Void) -> Int {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(offset))
        var consumed = offset
        var carry = Data()
        while let chunk = try? fh.read(upToCount: 8 << 20), !chunk.isEmpty {
            var buf = carry; buf.append(chunk)
            var start = buf.startIndex
            while let nl = buf[start...].firstIndex(of: 0x0A) {
                body(buf[start..<nl])
                consumed += nl - start + 1
                start = nl + 1
            }
            carry = buf[start...]
        }
        return consumed
    }

    private static func has(_ line: Data, _ needle: String) -> Bool {
        line.range(of: Data(needle.utf8)) != nil
    }

    /// The byte test before any JSON is decoded: a word `commitCall` could match.
    private static func mentionsCommit(_ line: Data) -> Bool {
        has(line, "commit") || has(line, "merge") || has(line, "cherry-pick") || has(line, "revert")
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private static func readClaude(_ url: URL, from: Int, open known: Set<String>) -> Found {
        var f = Found()
        var waiting = known
        f.consumed = lines(url, from: from) { line in
            if has(line, "\"tool_use\""), has(line, "\"Bash\""), mentionsCommit(line) {
                guard let r = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let blocks = (r["message"] as? [String: Any])?["content"] as? [[String: Any]],
                      let at = date(r["timestamp"]) else { return }
                for b in blocks where b["type"] as? String == "tool_use" && b["name"] as? String == "Bash" {
                    guard let id = b["id"] as? String,
                          let cmd = (b["input"] as? [String: Any])?["command"] as? String,
                          let dir = gitDirectory(cmd, cwd: r["cwd"] as? String ?? "") else { continue }
                    f.calls.append(Call(id: id, transcript: url.path, codex: false, start: at, end: nil,
                                        dir: dir, top: toplevel(dir), sha: ""))
                    waiting.insert(id)
                }
                return
            }
            // An answer, to one of the calls above — looked for by id before anything is decoded.
            guard !waiting.isEmpty, has(line, "\"tool_result\""),
                  let id = waiting.first(where: { has(line, $0) }),
                  let r = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let at = date(r["timestamp"]) else { return }
            var out = ""
            for b in ((r["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            where b["tool_use_id"] as? String == id {
                if let s = b["content"] as? String { out = s }
                else if let parts = b["content"] as? [[String: Any]] { out = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
            }
            waiting.remove(id)
            if let i = f.calls.lastIndex(where: { $0.id == id }) {
                let c = f.calls[i]
                f.calls[i] = Call(id: c.id, transcript: c.transcript, codex: false, start: c.start, end: at,
                                  dir: c.dir, top: c.top, sha: committedSha(out))
            } else {
                f.answers.append((id, at, committedSha(out)))
            }
        }
        return f
    }

    /// Codex reports a command once, finished: what ran, where, how long it took and what it printed.
    private static func readCodex(_ url: URL, from: Int) -> Found {
        var f = Found()
        f.consumed = lines(url, from: from) { line in
            guard has(line, "\"CommandExecution\""), has(line, "\"item_completed\""), mentionsCommit(line),
                  let r = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let item = (r["payload"] as? [String: Any])?["item"] as? [String: Any],
                  let id = item["id"] as? String, let end = date(r["timestamp"]) else { return }
            // `zsh -lc "<the command>"`: the script is the last argument.
            let cmd = (item["command"] as? [String])?.last ?? (item["command"] as? String ?? "")
            var cwd = item["cwd"] as? String ?? ""
            if cwd.hasPrefix("file://") { cwd = URL(string: cwd)?.path ?? cwd }
            guard let dir = gitDirectory(cmd, cwd: cwd) else { return }
            let d = item["duration"] as? [String: Any]
            let took = Double(d?["secs"] as? Int ?? 0) + Double(d?["nanos"] as? Int ?? 0) / 1e9
            f.calls.append(Call(id: id, transcript: url.path, codex: true, start: end.addingTimeInterval(-took),
                                end: end, dir: dir, top: toplevel(dir),
                                sha: committedSha(item["stdout"] as? String ?? item["aggregated_output"] as? String ?? "")))
        }
        return f
    }

    // MARK: - Where git ran

    /// What makes a commit: `git commit`, and the commands that write one of their own — a merge, a
    /// cherry-pick, a revert, and `gh pr merge`, whose merge commit GitHub makes during the call.
    /// Not `merge-base` or `commit-tree`, which only look. Not `rebase` or `pull` either: they rewrite
    /// or bring in commits other cards wrote.
    private static let commitCall = try! NSRegularExpression(
        pattern: #"(?:^|[;&|(\n]\s*|\s)(?:git\s+((?:-[Cc]\s+(?:"[^"]*"|'[^']*'|\S+)\s+)*)(?:commit|merge|cherry-pick|revert)(?![\w-])|gh\s+pr\s+merge(?![\w-]))"#)
    private static let changeDir = try! NSRegularExpression(
        pattern: #"(?:^|&&|;|\n|\|\|)\s*cd\s+("[^"]*"|'[^']*'|[^\s;&|]+)"#)
    private static let assignment = try! NSRegularExpression(
        pattern: #"(?:^|[;&\n]\s*|\s)(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|'[^']*'|[^\s;&|]+)"#)
    private static let shaLine = try! NSRegularExpression(pattern: #"^\[[^\]\s]+(?: \([^)]*\))? ([0-9a-f]{7,40})\]"#,
                                                         options: .anchorsMatchLines)

    /// The directory a command's `git commit` runs in, or nil when it has none. Follows the `cd`s
    /// before it and a `git -C`, with the variables the command itself assigns (`S=…; cd $S`); a
    /// path it cannot resolve leaves the directory where it was.
    static func gitDirectory(_ cmd: String, cwd: String) -> String? {
        let ns = cmd as NSString
        guard let m = commitCall.firstMatch(in: cmd, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var vars: [String: String] = [:]
        for a in assignment.matches(in: cmd, range: NSRange(location: 0, length: m.range.location)) {
            vars[ns.substring(with: a.range(at: 1))] = unquote(ns.substring(with: a.range(at: 2)))
        }
        var dir = cwd
        func move(_ raw: String) {
            var p = unquote(raw)
            for (k, v) in vars { p = p.replacingOccurrences(of: "${\(k)}", with: v).replacingOccurrences(of: "$\(k)", with: v) }
            guard !p.contains("$"), !p.isEmpty, p != "-" else { return }
            if p.hasPrefix("~") { p = NSHomeDirectory() + p.dropFirst() }
            dir = p.hasPrefix("/") ? p : (dir as NSString).appendingPathComponent(p)
        }
        for c in changeDir.matches(in: cmd, range: NSRange(location: 0, length: m.range.location)) {
            move(ns.substring(with: c.range(at: 1)))
        }
        let flags = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
        let parts = flags.split(whereSeparator: \.isWhitespace).map(String.init)
        for (i, p) in parts.enumerated() where p == "-C" && i + 1 < parts.count { move(parts[i + 1]) }
        return dir.isEmpty ? nil : (dir as NSString).standardizingPath
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f { return String(s.dropFirst().dropLast()) }
        return s
    }

    /// The repository a directory is in: the nearest folder above it holding `.git` (a worktree's is
    /// a file). Found on disk rather than asked of git, so a directory deleted since still finds the
    /// repository it was inside.
    static func toplevel(_ dir: String) -> String {
        var d = dir
        let fm = FileManager.default
        while d.count > 1 {
            if fm.fileExists(atPath: d + "/.git") { return d }
            d = (d as NSString).deletingLastPathComponent
        }
        return ""
    }

    /// A repository in a temporary folder: the throwaway ones agents build to test against (a
    /// FleetView card had made eight under its scratchpad). Kept in the ledger, left out of every list
    /// — nobody goes looking for those commits, and they would bury the real ones.
    static func isScratch(_ top: String) -> Bool {
        ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", NSTemporaryDirectory()]
            .contains { top.hasPrefix($0) }
    }

    /// The calls worth listing: in a repository that still exists and is not a throwaway one.
    static func listable(_ calls: [Call]) -> [Call] { calls.filter { !$0.top.isEmpty && !isScratch($0.top) } }

    static func committedSha(_ out: String) -> String {
        let ns = out as NSString
        guard let m = shaLine.firstMatch(in: out, range: NSRange(location: 0, length: ns.length)) else { return "" }
        return ns.substring(with: m.range(at: 1))
    }

    // MARK: - Asking

    /// The calls made in a repository over a span — what the commits listed for it are matched with.
    static func calls(inRepo top: String, from: Date, to: Date) -> [Call] {
        queue.sync {
            guard let db = open() else { return [] }
            return rows(db, "SELECT \(columns) FROM call WHERE top = ? AND t0 BETWEEN ? AND ?") { s in
                bind(s, 1, top)
                sqlite3_bind_double(s, 2, from.timeIntervalSince1970 - 600)
                sqlite3_bind_double(s, 3, to.timeIntervalSince1970 + 5)
            }
        }
    }

    /// The calls made in these conversations — one card's, across every repository.
    static func calls(inTranscripts paths: [String]) -> [Call] {
        guard !paths.isEmpty else { return [] }
        return queue.sync {
            guard let db = open() else { return [] }
            // In batches: a project's cards have had hundreds of conversations, and SQLite limits how
            // many values one statement can take.
            var out: [Call] = []
            for start in stride(from: 0, to: paths.count, by: 400) {
                let batch = Array(paths[start..<min(start + 400, paths.count)])
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                out += rows(db, "SELECT \(columns) FROM call WHERE transcript IN (\(marks))") { s in
                    for (i, p) in batch.enumerated() { bind(s, Int32(i + 1), p) }
                }
            }
            return out.sorted { $0.start > $1.start }
        }
    }

    /// Which call made each commit: the one whose output named it, else the one it was committed
    /// during — the narrowest, when calls overlap.
    static func attribute(_ commits: [(sha: String, committed: Date)], to calls: [Call]) -> [String: Call] {
        var out: [String: Call] = [:]
        for c in commits {
            if let named = calls.first(where: { !$0.sha.isEmpty && c.sha.hasPrefix($0.sha) }) { out[c.sha] = named; continue }
            let during = calls.filter { $0.window.contains(c.committed) }
            if let best = during.min(by: { span($0) < span($1) }) { out[c.sha] = best }
        }
        return out
    }

    private static func span(_ c: Call) -> TimeInterval { c.window.upperBound.timeIntervalSince(c.window.lowerBound) }

    private static let columns = "id, transcript, codex, t0, t1, dir, top, sha"

    private static func rows(_ db: OpaquePointer, _ sql: String, bindings: (OpaquePointer?) -> Void) -> [Call] {
        var out: [Call] = []
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        bindings(s)
        while sqlite3_step(s) == SQLITE_ROW {
            out.append(Call(id: text(s, 0), transcript: text(s, 1), codex: sqlite3_column_int(s, 2) == 1,
                            start: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                            end: sqlite3_column_type(s, 4) == SQLITE_NULL ? nil
                                : Date(timeIntervalSince1970: sqlite3_column_double(s, 4)),
                            dir: text(s, 5), top: text(s, 6), sha: text(s, 7)))
        }
        return out
    }

    private static func query(_ db: OpaquePointer, _ sql: String, _ each: (OpaquePointer?) -> Void) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW { each(s) }
    }

    private static func text(_ s: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    private static func bind(_ s: OpaquePointer?, _ i: Int32, _ v: String) {
        sqlite3_bind_text(s, i, v, -1, transient)
    }
}
