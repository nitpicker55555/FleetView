import Foundation
import SQLite3

/// Full-text search over every local Claude Code and Codex conversation.
///
/// The corpus is ~12 GB of jsonl, but conversation is a sliver of it: prompts and agent replies
/// together are ~62 MB, while tool *results* alone are ~7.5 GB. Indexing only what was actually
/// said keeps the index at ~150 MB and a full build at a few seconds; indexing tool output would
/// mean a ~15 GB index whose hits are mostly build logs. So only `user` and `assistant` text is
/// stored — which is also exactly the prompt/reply axis the search UI offers.
///
/// Incremental by byte offset: every file records how far it has been read, so a refresh only
/// parses appended tails. A no-op refresh over 4,700 files costs ~0.1 s, which is what makes it
/// affordable to re-run each time the panel opens.
enum SearchIndex {

    // MARK: - Shape

    enum Source: Int { case claude = 0, codex = 1 }
    enum Role: Int { case user = 0, assistant = 1 }

    /// One indexed message. `node` is what the "open" action resolves against: for Claude the
    /// record's own uuid, for Codex `"<session-id>:<n>"` — treeflow's node address, where n is the
    /// 0-based position of the prompt in the rollout (verified to match treeflow exactly).
    struct Hit: Identifiable, Hashable {
        let id: Int64
        let src: Source
        let role: Role
        let ts: String
        let path: String
        let node: String
        let body: String
        let session: String
        let project: String
    }

    // MARK: - Location

    static var dbURL: URL { FV.supportDir.appendingPathComponent("search.db") }
    private static var claudeRoot: URL { FV.home.appendingPathComponent(".claude/projects") }
    private static var codexRoot: URL { FV.home.appendingPathComponent(".codex/sessions") }

    // MARK: - CJK tokenisation
    //
    // FTS5's `unicode61` tokenizer treats an unbroken run of Han as ONE token, so a search for
    // 搜索 would never match 搜索能力 — the index holds a single token 搜索能力 and nothing splits
    // it. `trigram` handles substrings but needs 3+ characters, which fails the very common
    // two-character Chinese word. So each CJK character is emitted as its own token at index time,
    // and queries are turned into adjacent-token phrases (see `matchExpression`). English is
    // untouched and still tokenises on word boundaries.

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3400...0x4DBF,     // CJK ext A
             0x4E00...0x9FFF,     // CJK unified
             0xF900...0xFAFF,     // compatibility ideographs
             0x3040...0x30FF,     // hiragana + katakana
             0xAC00...0xD7AF,     // hangul syllables
             0x20000...0x2FA1F:   // CJK ext B+ (surrogate range, arrives as one scalar)
            return true
        default:
            return false
        }
    }

    /// Space out CJK so every ideograph becomes a standalone FTS5 token.
    static func segment(_ s: String) -> String {
        // Fast path: pure-ASCII text (the majority of agent replies) needs no work at all.
        if s.unicodeScalars.allSatisfy({ $0.isASCII }) { return s }
        var out = String()
        out.reserveCapacity(s.count + s.count / 2)
        for u in s.unicodeScalars {
            if isCJK(u) {
                out.unicodeScalars.append(" ")
                out.unicodeScalars.append(u)
                out.unicodeScalars.append(" ")
            } else {
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// The literal terms in a query, as typed: whitespace separates them, `"…"` keeps one together.
    ///
    /// Shared with the UI so highlighting marks exactly what the index matched on. Doing it any
    /// other way drifts: a two-word query is two independent AND-ed terms to FTS5, and highlighting
    /// the whole string as one substring would mark nothing at all.
    static func terms(_ query: String) -> [String] {
        var out: [String] = []
        var buf = String()
        var inQuotes = false

        func flush() {
            defer { buf = "" }
            let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
        }
        for ch in query {
            if ch == "\"" {
                if inQuotes { flush() }
                inQuotes.toggle()
            } else if ch.isWhitespace && !inQuotes {
                flush()
            } else {
                buf.append(ch)
            }
        }
        flush()
        return out
    }

    /// Turn what the user typed into an FTS5 MATCH expression.
    ///
    /// Terms are AND-ed, and every CJK run inside one becomes an adjacent-token phrase so it matches
    /// inside a longer run. Anything FTS5 would read as an operator is quoted away — a stray `*` or
    /// `-` in a query should search, not throw.
    static func matchExpression(_ query: String) -> String? {
        let parts: [String] = terms(query).compactMap { term in
            let tokens = segment(term).split(whereSeparator: { $0 == " " || $0.isNewline })
                .map { $0.replacingOccurrences(of: "\"", with: "") }
                .filter { !$0.isEmpty }
            guard !tokens.isEmpty else { return nil }
            return "\"" + tokens.joined(separator: " ") + "\""
        }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    // MARK: - Database

    private static let queue = DispatchQueue(label: "fleetview.search.index")
    private static var handle: OpaquePointer?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Open (creating if needed) and apply the schema. Serialised on `queue`.
    @discardableResult
    private static func open() -> OpaquePointer? {
        if let handle { return handle }
        FV.ensureSupportDir()
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            FV.log("search: cannot open \(dbURL.path)")
            return nil
        }
        // `synchronous=NORMAL` under WAL is the usual durability trade for a rebuildable cache:
        // a crash can cost the last commit, and the answer to that is to re-index, which is cheap.
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS file(
            path TEXT PRIMARY KEY,
            src INTEGER NOT NULL,
            done INTEGER NOT NULL,      -- bytes consumed so far
            prompts INTEGER NOT NULL,   -- user prompts seen (Codex node numbering continues from here)
            session TEXT NOT NULL,
            project TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS msg(
            id INTEGER PRIMARY KEY,
            src INTEGER NOT NULL,
            role INTEGER NOT NULL,
            ts TEXT NOT NULL,
            path TEXT NOT NULL,
            node TEXT NOT NULL,
            body TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS msg_path ON msg(path);
        CREATE VIRTUAL TABLE IF NOT EXISTS msg_fts
            USING fts5(seg, content='', tokenize='unicode61 remove_diacritics 2');
        """
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, schema, nil, nil, &err) != SQLITE_OK {
            FV.log("search: schema failed — \(err.map { String(cString: $0) } ?? "?")")
            sqlite3_free(err)
            sqlite3_close(db)
            return nil
        }
        handle = db
        return db
    }

    // MARK: - Build

    struct Progress { var files: Int; var total: Int; var messages: Int }

    private static var building = false

    /// True while a refresh is running (drives the UI's "indexing…" state).
    static var isBuilding: Bool { queue.sync { building } }

    /// Bring the index up to date. Safe to call often — an unchanged corpus costs ~0.1 s.
    /// Runs entirely on `queue`; `progress` is called there too, so hop to the main actor to draw.
    static func refresh(progress: ((Progress) -> Void)? = nil, done: (() -> Void)? = nil) {
        queue.async {
            guard !building else { done?(); return }
            building = true
            defer { building = false; done?() }
            build(progress: progress)
        }
    }

    private static func build(progress: ((Progress) -> Void)?) {
        guard let db = open() else { return }
        let started = Date()

        // What we already know, so unchanged files are skipped without opening them. `project` is
        // carried along too — see the write loop: a later pass must not be able to forget it.
        var seen: [String: (done: Int, prompts: Int, project: String)] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT path, done, prompts, project FROM file",
                              -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let p = String(cString: sqlite3_column_text(stmt, 0))
                seen[p] = (Int(sqlite3_column_int64(stmt, 1)), Int(sqlite3_column_int(stmt, 2)),
                           String(cString: sqlite3_column_text(stmt, 3)))
            }
        }
        sqlite3_finalize(stmt)

        // Claude keeps three layouts under a project slug — <sid>.jsonl, <sid>/*.jsonl and
        // <sid>/subagents/agent-*.jsonl — so enumerate rather than glob a fixed depth.
        var jobs: [(url: URL, src: Source, from: Int, prompts: Int, project: String)] = []
        for (root, src) in [(claudeRoot, Source.claude), (codexRoot, Source.codex)] {
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
            while let url = e?.nextObject() as? URL {
                guard url.pathExtension == "jsonl" else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let prior = seen[url.path] ?? (0, 0, "")
                if size > prior.done {
                    jobs.append((url, src, prior.done, prior.prompts, prior.project))
                }
            }
        }
        guard !jobs.isEmpty else { return }

        // Parse in parallel (JSON decoding is the whole cost), write serially.
        let lock = NSLock()
        var parsed = [Int: Parsed]()
        var completed = 0
        var messages = 0
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let job = jobs[i]
            let result = job.src == .claude
                ? parseClaude(job.url, from: job.from)
                : parseCodex(job.url, from: job.from, promptsBefore: job.prompts)
            lock.lock()
            parsed[i] = result
            completed += 1
            messages += result.rows.count
            let snapshot = Progress(files: completed, total: jobs.count, messages: messages)
            lock.unlock()
            if completed % 256 == 0 { progress?(snapshot) }
        }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var insertMsg: OpaquePointer?
        var insertFTS: OpaquePointer?
        var upsertFile: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO msg(src,role,ts,path,node,body) VALUES(?,?,?,?,?,?)",
                           -1, &insertMsg, nil)
        sqlite3_prepare_v2(db, "INSERT INTO msg_fts(rowid,seg) VALUES(?,?)", -1, &insertFTS, nil)
        sqlite3_prepare_v2(db, """
            INSERT INTO file(path,src,done,prompts,session,project) VALUES(?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET done=excluded.done, prompts=excluded.prompts,
                                            session=excluded.session, project=excluded.project
            """, -1, &upsertFile, nil)

        for i in 0..<jobs.count {
            guard let result = parsed[i] else { continue }
            let job = jobs[i]
            for row in result.rows {
                sqlite3_reset(insertMsg)
                sqlite3_bind_int(insertMsg, 1, Int32(job.src.rawValue))
                sqlite3_bind_int(insertMsg, 2, Int32(row.role.rawValue))
                bind(insertMsg, 3, row.ts)
                bind(insertMsg, 4, job.url.path)
                bind(insertMsg, 5, row.node)
                bind(insertMsg, 6, row.body)
                guard sqlite3_step(insertMsg) == SQLITE_DONE else { continue }
                sqlite3_reset(insertFTS)
                sqlite3_bind_int64(insertFTS, 1, sqlite3_last_insert_rowid(db))
                bind(insertFTS, 2, segment(row.body))
                sqlite3_step(insertFTS)
            }
            sqlite3_reset(upsertFile)
            bind(upsertFile, 1, job.url.path)
            sqlite3_bind_int(upsertFile, 2, Int32(job.src.rawValue))
            sqlite3_bind_int64(upsertFile, 3, Int64(result.consumed))
            sqlite3_bind_int(upsertFile, 4, Int32(result.prompts))
            bind(upsertFile, 5, result.session.isEmpty
                 ? job.url.deletingPathExtension().lastPathComponent : result.session)
            bind(upsertFile, 6, resolvedProject(result, job))
            sqlite3_step(upsertFile)
        }
        sqlite3_finalize(insertMsg)
        sqlite3_finalize(insertFTS)
        sqlite3_finalize(upsertFile)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        let elapsed = Date().timeIntervalSince(started)
        FV.log(String(format: "search: indexed %d msgs from %d files in %.1fs",
                      messages, jobs.count, elapsed))
        progress?(Progress(files: jobs.count, total: jobs.count, messages: messages))
    }

    private static func bind(_ stmt: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(stmt, i, s, -1, transient)
    }

    /// The folder to file this transcript under, which an incremental pass usually cannot see.
    ///
    /// `cwd` is not on every record: Claude repeats it on user/assistant lines but a chunk can be
    /// pure tool traffic, and Codex writes it exactly once, on the `session_meta` line at the head —
    /// so every pass after the first one over a growing rollout finds none. Overwriting the stored
    /// value with that emptiness is what left conversations un-openable ("could not determine the
    /// session's working directory") long after their folder had been recorded correctly.
    ///
    /// So: what this pass learned, else what was already known, else — only for a file that has
    /// never yielded one — one direct read of the file's head/tail. That last step is what heals a
    /// row already wiped by the old behaviour, and it costs nothing on the common path.
    private static func resolvedProject(_ result: Parsed,
                                        _ job: (url: URL, src: Source, from: Int,
                                                prompts: Int, project: String)) -> String {
        if !result.project.isEmpty { return result.project }
        if !job.project.isEmpty { return job.project }
        switch job.src {
        case .claude: return SessionForge.sessionCwd(transcriptPath: job.url.path) ?? ""
        case .codex:  return CodexSession.rolloutCwd(job.url.path) ?? ""
        }
    }

    // MARK: - Extraction

    private struct Row { let role: Role; let ts: String; let node: String; let body: String }
    private struct Parsed {
        var rows: [Row] = []
        var consumed: Int = 0
        var prompts: Int = 0
        var session: String = ""
        var project: String = ""
    }

    /// Injected wrappers that reach the transcript as `user` records but were never typed.
    private static let noise = ["<local-command", "<command-name", "<command-message",
                                "<command-args", "<system-reminder", "<user-memory",
                                "Caveat: The messages below", "[Request interrupted",
                                "<bash-input", "<bash-stdout", "<bash-stderr"]

    private static func cleanPrompt(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !noise.contains(where: { t.hasPrefix($0) }) else { return nil }
        // A reminder block glued onto the end of a real prompt is not part of what was said.
        if let r = t.range(of: "<system-reminder>"), r.lowerBound != t.startIndex {
            t = String(t[t.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t.isEmpty ? nil : t
    }

    /// Walk complete lines from `from`, stopping before a partial trailing line — a transcript
    /// being appended to right now must not have half a record indexed and then marked done.
    ///
    /// `wanted` is a byte-level pre-filter applied before any JSON parsing. That matters a lot:
    /// most of the corpus is tool traffic (all of Codex's `response_item` output, Claude's
    /// `tool_result` blocks), and decoding it only to throw it away dominated the build. Rejecting
    /// on a raw substring scan first cuts the JSON work to the lines that can actually contribute.
    /// It is only ever a *fast reject* — everything kept is still validated by the real parse.
    private static func forEachLine(_ url: URL, from: Int,
                                    wanted: (UnsafeBufferPointer<UInt8>, Int, Int) -> Bool,
                                    _ body: (Data) -> Void) -> Int {
        guard let h = try? FileHandle(forReadingFrom: url) else { return from }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(from))
        guard let data = try? h.readToEnd(), !data.isEmpty else { return from }

        var consumed = from
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let p = raw.bindMemory(to: UInt8.self)
            var start = 0
            var i = 0
            while i < p.count {
                guard p[i] == 0x0A else { i += 1; continue }
                let length = i - start
                if length > 1, wanted(p, start, i) {
                    body(Data(bytes: base.advanced(by: start), count: length))
                }
                consumed += length + 1
                start = i + 1
                i += 1
            }
        }
        return consumed
    }

    /// Substring search over a line's bytes.
    private static func has(_ p: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int,
                            _ needle: [UInt8]) -> Bool {
        let n = needle.count
        guard n > 0, hi - lo >= n else { return false }
        let first = needle[0]
        var i = lo
        let last = hi - n
        while i <= last {
            if p[i] == first {
                var k = 1
                while k < n, p[i + k] == needle[k] { k += 1 }
                if k == n { return true }
            }
            i += 1
        }
        return false
    }

    // Pre-filter needles. Claude records we care about are typed `user`/`assistant`; a line whose
    // only content is a tool_result carries neither text nor prompt, so it is dropped unless it
    // also holds a text block (assistant turns interleave prose with tool calls).
    private static let claudeUser: [UInt8] = Array("\"type\":\"user\"".utf8)
    private static let claudeAsst: [UInt8] = Array("\"type\":\"assistant\"".utf8)
    private static let toolResult: [UInt8] = Array("\"tool_result\"".utf8)
    private static let textBlock: [UInt8] = Array("\"type\":\"text\"".utf8)
    private static let stringContent: [UInt8] = Array("\"content\":\"".utf8)
    // Only message items carry a role, and only they carry a turn. A better reject than the record
    // type: `response_item` is most of a rollout, `"role":` is 8-12% of it.
    private static let codexRole: [UInt8] = Array("\"role\":\"".utf8)
    // `cwd` lives only on the rollout's opening session_meta record, so it has to survive the
    // filter even though it carries no conversation.
    private static let codexMeta: [UInt8] = Array("\"type\":\"session_meta\"".utf8)

    private static func wantClaude(_ p: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int) -> Bool {
        guard has(p, lo, hi, claudeUser) || has(p, lo, hi, claudeAsst) else { return false }
        guard has(p, lo, hi, toolResult) else { return true }
        // A tool_result line still counts when it carries prose — either a text block or a
        // plain-string content (the shape a typed prompt takes).
        return has(p, lo, hi, textBlock) || has(p, lo, hi, stringContent)
    }

    private static func wantCodex(_ p: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int) -> Bool {
        has(p, lo, hi, codexRole) || has(p, lo, hi, codexMeta)
    }

    private static func json(_ d: Data) -> [String: Any]? {
        guard d.count > 1 else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func parseClaude(_ url: URL, from: Int) -> Parsed {
        var out = Parsed()
        out.consumed = forEachLine(url, from: from, wanted: wantClaude) { line in
            guard let obj = json(line) else { return }
            if out.project.isEmpty, let cwd = obj["cwd"] as? String { out.project = cwd }
            if out.session.isEmpty, let sid = obj["sessionId"] as? String { out.session = sid }
            guard let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let uuid = obj["uuid"] as? String else { return }
            let role: Role = type == "user" ? .user : .assistant
            let ts = (obj["timestamp"] as? String) ?? ""

            if let s = message["content"] as? String {
                if let t = role == .user ? cleanPrompt(s) : trimmed(s) {
                    out.rows.append(Row(role: role, ts: ts, node: uuid, body: t))
                }
                return
            }
            guard let blocks = message["content"] as? [[String: Any]] else { return }
            for b in blocks where (b["type"] as? String) == "text" {
                guard let raw = b["text"] as? String,
                      let t = role == .user ? cleanPrompt(raw) : trimmed(raw) else { continue }
                out.rows.append(Row(role: role, ts: ts, node: uuid, body: t))
            }
        }
        return out
    }

    private static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Codex node addressing is positional: treeflow numbers a rollout's prompts 0..N in file
    /// order and addresses them `"<session-id>:<n>"`. `promptsBefore` carries that counter across
    /// an incremental read so a tail keeps numbering where the last pass stopped.
    private static func parseCodex(_ url: URL, from: Int, promptsBefore: Int) -> Parsed {
        var out = Parsed()
        out.prompts = promptsBefore
        // The filename carries the session uuid, so numbering never has to wait for session_meta
        // (an incremental read starts past it).
        let sid = codexSessionId(url)
        out.session = sid
        out.consumed = forEachLine(url, from: from, wanted: wantCodex) { line in
            guard let obj = json(line), let payload = obj["payload"] as? [String: Any] else { return }
            if out.project.isEmpty, let cwd = payload["cwd"] as? String { out.project = cwd }
            // Read from `response_item` messages, as treeflow does and as Codex 0.147 requires: the
            // parallel `event_msg` stream this used to count is gone. Kept identical to
            // `CodexTree.turns` — the tree and this index address the same nodes.
            guard (obj["type"] as? String) == "response_item",
                  (payload["type"] as? String) == "message",
                  let role = payload["role"] as? String else { return }
            let ts = (obj["timestamp"] as? String) ?? ""
            switch role {
            case "user":
                let raw = CodexTree.contentText(payload)
                // Never a node for treeflow, so never one here: counting it would shift every
                // address after it.
                guard CodexTree.isRealUserText(raw) else { return }
                guard let t = cleanPrompt(raw) else {
                    // Still a node as far as treeflow is concerned — keep the counter aligned.
                    out.prompts += 1
                    return
                }
                out.rows.append(Row(role: .user, ts: ts, node: "\(sid):\(out.prompts)", body: t))
                out.prompts += 1
            case "assistant":
                guard let t = trimmed(CodexTree.contentText(payload)) else { return }
                // A reply belongs to the prompt it answers — the last one seen.
                out.rows.append(Row(role: .assistant, ts: ts,
                                    node: "\(sid):\(max(0, out.prompts - 1))", body: t))
            default:
                return
            }
        }
        return out
    }

    /// `rollout-2026-07-19T02-14-32-<uuid>.jsonl` → `<uuid>`.
    private static func codexSessionId(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        // The uuid is the last five dash-separated groups.
        let parts = name.split(separator: "-")
        guard parts.count >= 5 else { return name }
        return parts.suffix(5).joined(separator: "-")
    }

    // MARK: - Query

    struct Scope: OptionSet, Hashable {
        let rawValue: Int
        static let prompts = Scope(rawValue: 1 << 0)
        static let replies = Scope(rawValue: 1 << 1)
        static let both: Scope = [.prompts, .replies]
    }

    /// Ranked hits for `query`. BM25 ordering, newest-first among equals.
    ///
    /// `paths` narrows to specific transcripts — that is how "search this conversation" is served
    /// off the same index as "search everything", instead of a second code path that reads the file.
    static func search(_ query: String, scope: Scope = .both, limit: Int = 200,
                       source: Source? = nil, paths: [String] = []) -> [Hit] {
        queue.sync {
            guard let db = open(), let match = matchExpression(query) else { return [] }
            var roles: [Int] = []
            if scope.contains(.prompts) { roles.append(Role.user.rawValue) }
            if scope.contains(.replies) { roles.append(Role.assistant.rawValue) }
            guard !roles.isEmpty else { return [] }

            var sql = """
            SELECT m.id, m.src, m.role, m.ts, m.path, m.node, m.body,
                   f.session, f.project, bm25(msg_fts) AS rank
            FROM msg_fts JOIN msg m ON m.id = msg_fts.rowid
            LEFT JOIN file f ON f.path = m.path
            WHERE msg_fts MATCH ? AND m.role IN (\(roles.map { _ in "?" }.joined(separator: ",")))
            """
            if source != nil { sql += " AND m.src = ?" }
            if !paths.isEmpty {
                sql += " AND m.path IN (\(paths.map { _ in "?" }.joined(separator: ",")))"
            }
            sql += " ORDER BY rank, m.ts DESC LIMIT ?"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                FV.log("search: bad query — \(String(cString: sqlite3_errmsg(db)))")
                return []
            }
            defer { sqlite3_finalize(stmt) }
            var i: Int32 = 1
            bind(stmt, i, match); i += 1
            for r in roles { sqlite3_bind_int(stmt, i, Int32(r)); i += 1 }
            if let source { sqlite3_bind_int(stmt, i, Int32(source.rawValue)); i += 1 }
            for p in paths { bind(stmt, i, p); i += 1 }
            sqlite3_bind_int(stmt, i, Int32(limit))

            var hits: [Hit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ c: Int32) -> String {
                    sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? ""
                }
                hits.append(Hit(
                    id: sqlite3_column_int64(stmt, 0),
                    src: Source(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .claude,
                    role: Role(rawValue: Int(sqlite3_column_int(stmt, 2))) ?? .user,
                    ts: text(3), path: text(4), node: text(5), body: text(6),
                    session: text(7), project: text(8)))
            }
            return hits
        }
    }

    /// Every message of one transcript, in file order.
    ///
    /// The windowed `context` is what paints first — it is two small queries and arrives instantly.
    /// This is what replaces it, because a hit read seven messages either side is a fragment, and
    /// the question a result raises is usually what the conversation did next. Served from the
    /// index like the window, so it still touches no transcript file.
    ///
    /// Capped: a long Codex rollout runs to thousands of rows, and past a few thousand the answer
    /// stops being "the conversation" and starts being a scroll nobody finishes. The cap keeps the
    /// *end* of the conversation, which is where it was going.
    static func conversation(of hit: Hit, limit: Int = 4000) -> [Hit] {
        queue.sync {
            guard let db = open() else { return [] }
            var stmt: OpaquePointer?
            // `msg` holds no session/project columns — those live on `file`, and the hit already
            // carries them for this transcript. Same shape `context` reads.
            let sql = """
                SELECT id, role, ts, node, body FROM msg
                WHERE path = ? ORDER BY id DESC LIMIT ?
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, hit.path)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var out: [Hit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ c: Int32) -> String {
                    sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? ""
                }
                out.append(Hit(id: sqlite3_column_int64(stmt, 0),
                               src: hit.src,
                               role: Role(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .user,
                               ts: text(2), path: hit.path, node: text(3), body: text(4),
                               session: hit.session, project: hit.project))
            }
            return out.reversed()
        }
    }

    /// The conversation immediately around a hit, from the same transcript.
    ///
    /// This is what makes browsing results free. Resuming a node is what costs a synthesized
    /// session file (~10 MB, and on this corpus only 3% of nodes are natively resumable), so
    /// reading is served entirely from the index and touches no transcript at all.
    ///
    /// Rows are numbered in file order, so a window either side of the hit's rowid is the
    /// surrounding conversation. Taken as two bounded queries rather than one `BETWEEN`, because
    /// an incrementally-indexed tail gets rowids far above the file's original block.
    static func context(around hit: Hit, radius: Int = 7) -> [Hit] {
        queue.sync {
            guard let db = open() else { return [] }
            func window(_ sql: String, _ id: Int64, _ n: Int) -> [Hit] {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                defer { sqlite3_finalize(stmt) }
                bind(stmt, 1, hit.path)
                sqlite3_bind_int64(stmt, 2, id)
                sqlite3_bind_int(stmt, 3, Int32(n))
                var out: [Hit] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    func text(_ c: Int32) -> String {
                        sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? ""
                    }
                    out.append(Hit(id: sqlite3_column_int64(stmt, 0),
                                   src: hit.src,
                                   role: Role(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .user,
                                   ts: text(2), path: hit.path, node: text(3), body: text(4),
                                   session: hit.session, project: hit.project))
                }
                return out
            }
            let before = window("""
                SELECT id, role, ts, node, body FROM msg
                WHERE path = ? AND id <= ? ORDER BY id DESC LIMIT ?
                """, hit.id, radius + 1).reversed()
            let after = window("""
                SELECT id, role, ts, node, body FROM msg
                WHERE path = ? AND id > ? ORDER BY id ASC LIMIT ?
                """, hit.id, radius)
            return Array(before) + after
        }
    }

    // MARK: - Forks

    /// Mark a just-written fork as already-indexed up to its current size.
    ///
    /// A fork is a *copy* of a conversation that is already in the index, so letting the indexer
    /// read it would duplicate every prompt in it — and because opening a search hit is what
    /// creates forks, that would compound each time. Seeding the byte offset to the file's current
    /// length skips exactly the copied prefix while leaving normal incremental indexing to pick up
    /// whatever the resumed session goes on to do.
    ///
    /// Call right after the fork is written and before the terminal starts appending to it.
    static func excludeCopiedPrefix(path: String, src: Source, session: String, project: String) {
        queue.async {
            guard let db = open() else { return }
            let size = ((try? FileManager.default
                .attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
            guard size > 0 else { return }
            // Codex node addressing is positional, so the prompt counter has to start where the
            // copied prefix ends or every later node in this session would be misnumbered.
            let prompts = src == .codex ? countCodexPrompts(path) : 0
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                INSERT INTO file(path,src,done,prompts,session,project) VALUES(?,?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET done=excluded.done, prompts=excluded.prompts
                """, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, path)
            sqlite3_bind_int(stmt, 2, Int32(src.rawValue))
            sqlite3_bind_int64(stmt, 3, Int64(size))
            sqlite3_bind_int(stmt, 4, Int32(prompts))
            bind(stmt, 5, session)
            bind(stmt, 6, project)
            sqlite3_step(stmt)
            FV.log("search: fork excluded from index (\(size) bytes, \(prompts) prompts) \(path)")
        }
    }

    private static func countCodexPrompts(_ path: String) -> Int {
        var n = 0
        _ = forEachLine(URL(fileURLWithPath: path), from: 0, wanted: wantCodex) { line in
            guard let obj = json(line), (obj["type"] as? String) == "event_msg",
                  let p = obj["payload"] as? [String: Any],
                  (p["type"] as? String) == "user_message" else { return }
            n += 1
        }
        return n
    }

    /// Total messages held, for the panel's footer.
    static func stats() -> (messages: Int, files: Int) {
        queue.sync {
            guard let db = open() else { return (0, 0) }
            func count(_ sql: String) -> Int {
                var s: OpaquePointer?
                defer { sqlite3_finalize(s) }
                guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK,
                      sqlite3_step(s) == SQLITE_ROW else { return 0 }
                return Int(sqlite3_column_int64(s, 0))
            }
            return (count("SELECT count(*) FROM msg"), count("SELECT count(*) FROM file"))
        }
    }
}
