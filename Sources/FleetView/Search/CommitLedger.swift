import Foundation
import SQLite3
#if canImport(FleetViewFiles)
import FleetViewFiles
#endif

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
///
/// Everything a screen asks is answered from the file alone. Which commits a call landed on is worked
/// out once, when the call is over, one `git log` per repository for all its new calls, and written
/// down (`made`); which card each conversation was is copied from the audit log as it grows
/// (`binding`). The first version matched at the time of asking — a `git log` per call, through the
/// two git slots the file window's own status and diffs wait on — and the window crawled.
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
    /// Reads go through a connection of their own: under WAL they never wait for a pass to finish,
    /// which on the first launch takes half a minute.
    private static let readQueue = DispatchQueue(label: "fleetview.commit-ledger.read", qos: .userInitiated)
    private static var readHandle: OpaquePointer?
    private static var running = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var dbURL: URL { FV.supportDir.appendingPathComponent("commits.db") }

    // MARK: - Store

    private static func open() -> OpaquePointer? {
        if let handle { return handle }
        handle = connect()
        return handle
    }

    private static func reader() -> OpaquePointer? {
        if let readHandle { return readHandle }
        readHandle = connect()
        return readHandle
    }

    private static func connect() -> OpaquePointer? {
        FV.ensureSupportDir()
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else { return nil }
        sqlite3_busy_timeout(db, 5000)
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
            sha TEXT NOT NULL,
            resolved INTEGER NOT NULL DEFAULT 0   -- its commits are in `made`
        );
        CREATE INDEX IF NOT EXISTS call_top ON call(top, t0);
        CREATE INDEX IF NOT EXISTS call_transcript ON call(transcript);
        CREATE TABLE IF NOT EXISTS made(
            call TEXT NOT NULL,
            sha TEXT NOT NULL,
            top TEXT NOT NULL,
            committed REAL NOT NULL,
            author TEXT NOT NULL,
            subject TEXT NOT NULL,
            PRIMARY KEY(call, sha)
        );
        CREATE INDEX IF NOT EXISTS made_sha ON made(sha);
        CREATE TABLE IF NOT EXISTS repo(top TEXT PRIMARY KEY, common TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS binding(
            path TEXT PRIMARY KEY,
            terminal TEXT NOT NULL,
            name TEXT NOT NULL,
            project TEXT NOT NULL,
            cwd TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS auditscan(file TEXT PRIMARY KEY, done INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS edit(       -- every file an agent's tool call wrote
            id TEXT NOT NULL,
            path TEXT NOT NULL,
            transcript TEXT NOT NULL,
            born REAL NOT NULL,
            at REAL NOT NULL,
            PRIMARY KEY(id, path)
        );
        CREATE INDEX IF NOT EXISTS edit_path ON edit(path);
        CREATE INDEX IF NOT EXISTS edit_transcript ON edit(transcript);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        // A file from the first version has no `resolved`; adding it again to a new one only fails.
        sqlite3_exec(db, "ALTER TABLE call ADD COLUMN resolved INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        // Files written before `edit` existed were read past the lines it needs: read them again, once.
        // Calls and their commits are kept — reading a call twice changes nothing.
        var version: Int32 = 0
        query(db, "PRAGMA user_version") { s in version = sqlite3_column_int(s, 0) }
        if version < 3 {
            sqlite3_exec(db, "DELETE FROM scanned; PRAGMA user_version = 3", nil, nil, nil)
        }
        return db
    }

    // MARK: - Reading the transcripts

    /// Bring the ledger up to date: every transcript under `roots`, the audit log in `logs`, and the
    /// commits of every call that has finished. The first pass reads all of them (the lines it wants
    /// are found by byte search before any JSON is decoded); after that only what was appended.
    /// `canonical` puts a path as an agent reported it back where the ledger files it (AgentHome).
    /// `done` runs on the ledger's queue.
    static func refresh(roots: [(url: URL, codex: Bool)], logs: URL?, canonical: @escaping (String) -> String = { $0 },
                        done: (() -> Void)? = nil) {
        queue.async {
            defer { done?() }
            guard !running, let db = open() else { return }
            running = true
            defer { running = false }
            scan(db, roots: roots)
            if let logs { scanAudit(db, logs, canonical: canonical) }
            resolve(db)
        }
    }

    private struct Found {
        var calls: [Call] = []
        /// Files written: (tool call id, absolute path, when).
        var edits: [(String, String, Date)] = []
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
        var wrote: OpaquePointer?
        // Like a call, a write copied into a fork stays with the conversation that made it.
        sqlite3_prepare_v2(db, """
            INSERT INTO edit(id, path, transcript, born, at) VALUES(?,?,?,?,?)
            ON CONFLICT(id, path) DO UPDATE SET transcript=excluded.transcript, born=excluded.born, at=excluded.at
            WHERE excluded.born < edit.born
            """, -1, &wrote, nil)
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
            for (id, path, at) in r.edits {
                sqlite3_reset(wrote)
                bind(wrote, 1, id); bind(wrote, 2, path); bind(wrote, 3, main.path)
                sqlite3_bind_double(wrote, 4, born); sqlite3_bind_double(wrote, 5, at.timeIntervalSince1970)
                sqlite3_step(wrote)
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
        sqlite3_finalize(upsert); sqlite3_finalize(answer); sqlite3_finalize(mark); sqlite3_finalize(wrote)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        FV.log(String(format: "commits: read %d transcripts, %d commit calls, %d file writes, in %.1fs",
                      jobs.count, calls, results.values.reduce(0) { $0 + $1.edits.count }, Date().timeIntervalSince(started)))
    }

    // MARK: - Which card each conversation was

    /// The audit log's record of each conversation bound to a card (`transcript_bound`): a card goes
    /// through several — a `/clear`, a reopen that could not resume — and the board keeps only the
    /// last. Read by offset like the transcripts: the log runs to hundreds of megabytes, and only
    /// today's file grows. A later binding of the same conversation wins.
    private static func scanAudit(_ db: OpaquePointer, _ dir: URL, canonical: (String) -> String) {
        var seen: [String: Int] = [:]
        query(db, "SELECT file, done FROM auditscan") { s in seen[text(s, 0)] = Int(sqlite3_column_int64(s, 1)) }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("audit-") && $0.hasSuffix(".jsonl") }.sorted()
        var upsert: OpaquePointer?, mark: OpaquePointer?
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO binding(path, terminal, name, project, cwd) VALUES(?,?,?,?,?)",
                           -1, &upsert, nil)
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO auditscan(file, done) VALUES(?,?)", -1, &mark, nil)
        for f in files {
            let url = dir.appendingPathComponent(f)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            let from = seen[f] ?? 0
            guard size > from else { continue }
            let done = lines(url, from: from) { line in
                guard has(line, "\"fleetview.terminal.transcript_bound\""),
                      let r = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let target = r["fleetview.target"] as? [String: Any],
                      let id = target["terminal.id"] as? String,
                      let to = (r["fleetview.data"] as? [String: Any])?["transcript.to"] as? String else { return }
                sqlite3_reset(upsert)
                bind(upsert, 1, canonical(to)); bind(upsert, 2, id)
                bind(upsert, 3, target["terminal.name"] as? String ?? "")
                bind(upsert, 4, target["project.id"] as? String ?? "")
                bind(upsert, 5, target["terminal.cwd"] as? String ?? "")
                sqlite3_step(upsert)
            }
            sqlite3_reset(mark)
            bind(mark, 1, f); sqlite3_bind_int64(mark, 2, Int64(done))
            sqlite3_step(mark)
        }
        sqlite3_finalize(upsert); sqlite3_finalize(mark)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - Which commits each call made

    /// Work out, once, the commits of every call that is over — answered half a minute ago, or sent
    /// ten minutes ago and never answered — and write them down. One `git log` per repository for all
    /// of its new calls, weighed against every call made in it over the same span; a repository's
    /// worktrees are the same repository, since they share its commits. A commit already credited to
    /// a call stays with it.
    private static func resolve(_ db: OpaquePointer) {
        #if canImport(FleetViewFiles) || LEDGER_STANDALONE
        let started = Date()
        let now = started.timeIntervalSince1970
        let pending = rows(db, "SELECT \(columns) FROM call WHERE resolved = 0 AND ((t1 IS NOT NULL AND t1 < ?) OR (t1 IS NULL AND t0 < ?))") { s in
            sqlite3_bind_double(s, 1, now - 30)
            sqlite3_bind_double(s, 2, now - 600)
        }
        guard !pending.isEmpty else { return }

        // Each repository by its common git directory, which its worktrees share. Written down: a
        // directory is asked once, and one that has gone answers "" from then on.
        var common: [String: String] = [:]
        query(db, "SELECT top, common FROM repo") { s in common[text(s, 0)] = text(s, 1) }
        var learn: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO repo(top, common) VALUES(?,?)", -1, &learn, nil)
        for top in Set(pending.map(\.top)) where !top.isEmpty && !isScratch(top) && common[top] == nil {
            let c = GitReader.shared.repo(at: top)?.commonDir ?? ""
            common[top] = c
            sqlite3_reset(learn); bind(learn, 1, top); bind(learn, 2, c); sqlite3_step(learn)
        }
        sqlite3_finalize(learn)

        var groups: [String: [Call]] = [:]
        for c in pending where !c.top.isEmpty && !isScratch(c.top) {
            if let dir = common[c.top], !dir.isEmpty { groups[dir, default: []].append(c) }
        }
        var found: [(Call, GitCommit)] = []
        for (dir, calls) in groups {
            let tops = common.filter { $0.value == dir }.map(\.key)
            guard let lo = calls.map(\.window.lowerBound).min(), let hi = calls.map(\.window.upperBound).max(),
                  let here = tops.first(where: { FileManager.default.fileExists(atPath: $0) }),
                  let repo = GitReader.shared.repo(at: here) else { continue }
            let marks = Array(repeating: "?", count: tops.count).joined(separator: ",")
            let rivals = rows(db, "SELECT \(columns) FROM call WHERE top IN (\(marks)) AND t0 BETWEEN ? AND ?") { s in
                for (i, t) in tops.enumerated() { bind(s, Int32(i + 1), t) }
                sqlite3_bind_double(s, Int32(tops.count + 1), lo.timeIntervalSince1970 - 600)
                sqlite3_bind_double(s, Int32(tops.count + 2), hi.timeIntervalSince1970)
            }
            var claimed = Set<String>()
            query(db, "SELECT sha FROM made WHERE committed BETWEEN \(lo.timeIntervalSince1970) AND \(hi.timeIntervalSince1970)") { s in
                claimed.insert(text(s, 0))
            }
            let commits = GitReader.shared.commits(repo, from: lo, to: hi, limit: 100_000).filter { !claimed.contains($0.sha) }
            let mine = Set(calls.map(\.id))
            let made = attribute(commits.map { (sha: $0.sha, committed: $0.committed) }, to: rivals)
            for c in commits { if let call = made[c.sha], mine.contains(call.id) { found.append((call, c)) } }
        }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var write: OpaquePointer?, done: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO made(call, sha, top, committed, author, subject) VALUES(?,?,?,?,?,?)",
                           -1, &write, nil)
        sqlite3_prepare_v2(db, "UPDATE call SET resolved = 1 WHERE id = ?", -1, &done, nil)
        for (call, c) in found {
            sqlite3_reset(write)
            bind(write, 1, call.id); bind(write, 2, c.sha); bind(write, 3, call.top)
            sqlite3_bind_double(write, 4, c.committed.timeIntervalSince1970)
            bind(write, 5, c.author); bind(write, 6, c.subject)
            sqlite3_step(write)
        }
        for c in pending { sqlite3_reset(done); bind(done, 1, c.id); sqlite3_step(done) }
        sqlite3_finalize(write); sqlite3_finalize(done)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        FV.log(String(format: "commits: matched %d calls in %d repositories to %d commits in %.1fs",
                      pending.count, groups.count, found.count, Date().timeIntervalSince(started)))
        #endif
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

    /// The byte test for a Claude tool call that writes files (EditedPaths reads which).
    private static func writesFiles(_ line: Data) -> Bool {
        has(line, "\"name\":\"Edit\"") || has(line, "\"name\":\"Write\"") || has(line, "\"name\":\"MultiEdit\"")
            || has(line, "\"name\":\"NotebookEdit\"")
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
            let commit = has(line, "\"Bash\"") && mentionsCommit(line)
            if has(line, "\"tool_use\""), commit || writesFiles(line) {
                guard let r = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let blocks = (r["message"] as? [String: Any])?["content"] as? [[String: Any]],
                      let at = date(r["timestamp"]) else { return }
                let cwd = r["cwd"] as? String ?? ""
                for b in blocks where b["type"] as? String == "tool_use" {
                    guard let id = b["id"] as? String else { continue }
                    let name = b["name"] as? String, input = b["input"] as? [String: Any]
                    if name == "Bash" {
                        guard let cmd = input?["command"] as? String,
                              let dir = gitDirectory(cmd, cwd: cwd) else { continue }
                        f.calls.append(Call(id: id, transcript: url.path, codex: false, start: at, end: nil,
                                            dir: dir, top: toplevel(dir), sha: ""))
                        waiting.insert(id)
                    } else {
                        #if canImport(FleetViewFiles) || LEDGER_STANDALONE
                        for p in EditedPaths.paths(tool: name, input: input, cwd: cwd) { f.edits.append((id, p, at)) }
                        #endif
                    }
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
            // A patch applied: every file it wrote, by absolute path.
            if has(line, "\"FileChange\""), has(line, "\"item_completed\""),
               let r = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let item = (r["payload"] as? [String: Any])?["item"] as? [String: Any],
               item["type"] as? String == "FileChange", let id = item["id"] as? String,
               let changes = item["changes"] as? [String: Any], let at = date(r["timestamp"]) {
                for p in changes.keys where p.hasPrefix("/") { f.edits.append((id, (p as NSString).standardizingPath, at)) }
                return
            }
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

    static func committedSha(_ out: String) -> String {
        let ns = out as NSString
        guard let m = shaLine.firstMatch(in: out, range: NSRange(location: 0, length: ns.length)) else { return "" }
        return ns.substring(with: m.range(at: 1))
    }

    // MARK: - Asking

    /// One commit, as written down for the call that made it.
    struct Made: Sendable, Hashable {
        let sha: String
        let top: String
        let committed: Date
        let author: String
        let subject: String
        /// The conversation of the call.
        let transcript: String
    }

    /// The commits made in these conversations — one card's, every repository — newest first.
    static func made(inTranscripts paths: [String]) -> [Made] {
        guard !paths.isEmpty else { return [] }
        return readQueue.sync {
            guard let db = reader() else { return [] }
            // In batches: a project's cards have had hundreds of conversations, and SQLite limits how
            // many values one statement can take.
            var out: [Made] = []
            for start in stride(from: 0, to: paths.count, by: 400) {
                let batch = Array(paths[start..<min(start + 400, paths.count)])
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                out += madeRows(db, "WHERE c.transcript IN (\(marks))") { s in
                    for (i, p) in batch.enumerated() { bind(s, Int32(i + 1), p) }
                }
            }
            return out.sorted { $0.committed > $1.committed }
        }
    }

    /// Who made these commits: each one's conversation, by sha.
    static func conversations(of shas: [String]) -> [String: String] {
        guard !shas.isEmpty else { return [:] }
        return readQueue.sync {
            guard let db = reader() else { return [:] }
            var out: [String: String] = [:]
            for start in stride(from: 0, to: shas.count, by: 400) {
                let batch = Array(shas[start..<min(start + 400, shas.count)])
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                for m in madeRows(db, "WHERE m.sha IN (\(marks))", { s in
                    for (i, p) in batch.enumerated() { bind(s, Int32(i + 1), p) }
                }) { out[m.sha] = m.transcript }
            }
            return out
        }
    }

    /// Every commit written down, without the scratch ones: what the cards' counts are made from.
    static func allMade() -> [Made] {
        readQueue.sync {
            guard let db = reader() else { return [] }
            return madeRows(db, "", { _ in }).filter { !isScratch($0.top) }
        }
    }

    /// The files written in these conversations — one card's — each with the last time it was.
    static func edits(inTranscripts paths: [String]) -> [String: Date] {
        guard !paths.isEmpty else { return [:] }
        return readQueue.sync {
            guard let db = reader() else { return [:] }
            var out: [String: Date] = [:]
            for start in stride(from: 0, to: paths.count, by: 400) {
                let batch = Array(paths[start..<min(start + 400, paths.count)])
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                var s: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT path, MAX(at) FROM edit WHERE transcript IN (\(marks)) GROUP BY path",
                                         -1, &s, nil) == SQLITE_OK else { continue }
                for (i, p) in batch.enumerated() { bind(s, Int32(i + 1), p) }
                while sqlite3_step(s) == SQLITE_ROW {
                    let d = Date(timeIntervalSince1970: sqlite3_column_double(s, 1))
                    out[text(s, 0)] = max(out[text(s, 0)] ?? .distantPast, d)
                }
                sqlite3_finalize(s)
            }
            return out
        }
    }

    /// Every conversation that wrote each of these files, the latest first, with when it last did.
    static func writers(of files: [String]) -> [String: [(transcript: String, at: Date)]] {
        guard !files.isEmpty else { return [:] }
        return readQueue.sync {
            guard let db = reader() else { return [:] }
            var out: [String: [(transcript: String, at: Date)]] = [:]
            for start in stride(from: 0, to: files.count, by: 400) {
                let batch = Array(files[start..<min(start + 400, files.count)])
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                var s: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT path, transcript, MAX(at) FROM edit WHERE path IN (\(marks)) GROUP BY path, transcript",
                                         -1, &s, nil) == SQLITE_OK else { continue }
                for (i, p) in batch.enumerated() { bind(s, Int32(i + 1), p) }
                while sqlite3_step(s) == SQLITE_ROW {
                    out[text(s, 0), default: []].append((text(s, 1), Date(timeIntervalSince1970: sqlite3_column_double(s, 2))))
                }
                sqlite3_finalize(s)
            }
            return out.mapValues { $0.sorted { $0.at > $1.at } }
        }
    }

    /// The conversation that wrote each of these files last, whoever's it was.
    static func lastWriters(of files: [String]) -> [String: String] {
        guard !files.isEmpty else { return [:] }
        return readQueue.sync {
            guard let db = reader() else { return [:] }
            var out: [String: String] = [:]
            for start in stride(from: 0, to: files.count, by: 400) {
                let batch = Array(files[start..<min(start + 400, files.count)])
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                var s: OpaquePointer?
                // SQLite answers a bare column beside MAX() from the row that holds the maximum.
                guard sqlite3_prepare_v2(db, "SELECT path, transcript, MAX(at) FROM edit WHERE path IN (\(marks)) GROUP BY path",
                                         -1, &s, nil) == SQLITE_OK else { continue }
                for (i, p) in batch.enumerated() { bind(s, Int32(i + 1), p) }
                while sqlite3_step(s) == SQLITE_ROW { out[text(s, 0)] = text(s, 1) }
                sqlite3_finalize(s)
            }
            return out
        }
    }

    /// Each repository the ledger has seen, by top level: its common git directory, which its
    /// worktrees share ("" for one that has gone).
    static func commonDirs() -> [String: String] {
        readQueue.sync {
            guard let db = reader() else { return [:] }
            var out: [String: String] = [:]
            query(db, "SELECT top, common FROM repo") { s in out[text(s, 0)] = text(s, 1) }
            return out
        }
    }

    /// Every conversation the audit log saw bound to a card.
    struct Binding: Sendable { let terminal: UUID; let name: String; let project: UUID?; let cwd: String?; let path: String }

    static func bindings() -> [Binding] {
        readQueue.sync {
            guard let db = reader() else { return [] }
            var out: [Binding] = []
            query(db, "SELECT path, terminal, name, project, cwd FROM binding") { s in
                guard let id = UUID(uuidString: text(s, 1)) else { return }
                let cwd = text(s, 4)
                out.append(Binding(terminal: id, name: text(s, 2), project: UUID(uuidString: text(s, 3)),
                                   cwd: cwd.isEmpty ? nil : cwd, path: text(s, 0)))
            }
            return out
        }
    }

    private static func madeRows(_ db: OpaquePointer, _ filter: String, _ bindings: (OpaquePointer?) -> Void) -> [Made] {
        var out: [Made] = []
        var s: OpaquePointer?
        let sql = "SELECT m.sha, m.top, m.committed, m.author, m.subject, c.transcript FROM made m JOIN call c ON c.id = m.call " + filter
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        bindings(s)
        while sqlite3_step(s) == SQLITE_ROW {
            out.append(Made(sha: text(s, 0), top: text(s, 1), committed: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
                            author: text(s, 3), subject: text(s, 4), transcript: text(s, 5)))
        }
        return out
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
