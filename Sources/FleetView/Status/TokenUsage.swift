import Foundation

/// Parses a Claude Code or Codex CLI transcript into a cumulative "new tokens" time series.
///
/// "New tokens" = fresh input + cache writes + output. Cache *reads* are excluded — they're reused
/// context, not new consumption. This matches how usage/cost is usually reckoned.
///  • Claude: each assistant message carries `message.usage`; we sum per message (de-duped by id).
///  • Codex:  `token_count` events carry a cumulative `total_token_usage`; we read it directly.
enum TokenUsage {
    struct Sample { let t: Date; let cumulativeNew: Int }

    /// Read `path` (plus Claude subagent transcripts) → cumulative new-token curve, sorted by time.
    ///
    /// Incremental. This used to read every file whole and JSON-parse every line on each call —
    /// and it is called up to once a second per working terminal. On this machine's transcripts
    /// that was 4.0 s of CPU for a 42 MB one and 1.1 s for 28.8 MB, with one call peaking at
    /// 467 MB (each line's Foundation objects lived until the whole file was done), and nothing
    /// stopped the next call starting before the last one finished. Now each file is read from
    /// where the previous call stopped, a chunk at a time; only a line that can carry usage is
    /// parsed at all; and a file that was replaced or shrank makes the whole ledger start over,
    /// so the answer is the one a full read would give.
    static func series(path: String) -> [Sample] {
        // Claude writes each subagent's turns to a sibling dir: <transcript w/o .jsonl>/subagents/agent-*.jsonl
        // Those tokens are real usage but live outside the main transcript, so include them.
        var files = [path]
        if path.hasSuffix(".jsonl") {
            let subDir = String(path.dropLast(6)) + "/subagents"
            if let subs = try? FileManager.default.contentsOfDirectory(atPath: subDir) {
                for f in subs where f.hasPrefix("agent-") && f.hasSuffix(".jsonl") { files.append(subDir + "/" + f) }
            }
        }

        let ledger = ledger(for: path)
        ledger.lock.lock()
        defer { ledger.lock.unlock() }

        // A file whose identity changed, or that is shorter than what was already read, was rewritten:
        // its earlier lines may be gone or different, and they are mixed into the totals with the
        // others', so everything is read again.
        let stats = files.map { file -> (size: UInt64, inode: UInt64)? in
            guard let a = try? FileManager.default.attributesOfItem(atPath: file) else { return nil }
            return ((a[.size] as? NSNumber)?.uint64Value ?? 0, (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        }
        for (file, st) in zip(files, stats) {
            guard let st, let known = ledger.read[file] else { continue }
            if known.inode != st.inode || st.size < known.offset { ledger.reset(); break }
        }
        for (file, st) in zip(files, stats) {
            guard let st else { continue }
            let known = ledger.read[file]
            let from = known?.offset ?? 0
            guard st.size > from else { continue }
            let consumed = ledger.consume(file: file, from: from, to: st.size)
            ledger.read[file] = (from + consumed, st.inode)
        }

        // Codex: cumulative snapshots, clamped non-decreasing (it can interleave sub-thread counters).
        if !ledger.codex.isEmpty {
            var peak = 0
            return ledger.codex.sorted { $0.t != $1.t ? $0.t < $1.t : $0.seq < $1.seq }
                .map { peak = max(peak, $0.n); return Sample(t: $0.t, cumulativeNew: peak) }
        }
        // Claude: accumulate per-message increments in time order (main + subagents interleaved).
        var cum = 0
        return ledger.claude.sorted { $0.t != $1.t ? $0.t < $1.t : $0.seq < $1.seq }
            .map { cum += $0.n; return Sample(t: $0.t, cumulativeNew: cum) }
    }

    /// What has been read of one transcript (and its subagents) so far.
    private final class Ledger {
        let lock = NSLock()
        var read: [String: (offset: UInt64, inode: UInt64)] = [:]
        var claude: [(t: Date, n: Int, seq: Int)] = []
        var codex: [(t: Date, n: Int, seq: Int)] = []
        // Claude assistant message ids, across all the files. The first copy of a message is the one
        // counted, as it always was. In a session whose subagent files repeat messages a later copy
        // can carry the larger, final usage — measured up to 20% more on this machine's sessions.
        var seen = Set<String>()
        var seq = 0
        var used = Date()               // touched only under `ledgersLock`

        func reset() { read = [:]; claude = []; codex = []; seen = []; seq = 0 }

        /// Read `file` from `from` up to `to`, parse every complete line, and say how many bytes
        /// that was — a trailing line still being written is left for the next call.
        func consume(file: String, from: UInt64, to: UInt64) -> UInt64 {
            guard let h = FileHandle(forReadingAtPath: file) else { return 0 }
            defer { try? h.close() }
            var consumed: UInt64 = 0
            var carry = Data()
            var pos = from
            try? h.seek(toOffset: from)
            var ended = false
            while pos < to, !ended {
                // One pool per chunk, the read included: FileHandle hands each chunk back
                // autoreleased, so without it every chunk lived until the whole call was over —
                // measured, a first read held memory in proportion to everything it had read
                // (350 MB for one session's 299 MB of transcripts; 58 MB with this).
                autoreleasepool {
                    let want = Int(min(to - pos, 4 << 20))
                    guard let chunk = try? h.read(upToCount: want), !chunk.isEmpty else { ended = true; return }
                    pos += UInt64(chunk.count)
                    var buf = carry
                    buf.append(chunk)
                    guard let lastNL = buf.lastIndex(of: 0x0A) else { carry = buf; return }
                    parse(lines: buf[buf.startIndex...lastNL])
                    consumed += UInt64(buf.distance(from: buf.startIndex, to: lastNL) + 1)
                    carry = Data(buf[buf.index(after: lastNL)...])
                }
            }
            // A last line with no newline after it is either still being written or simply the
            // end of a file that never got one. Only the second parses, and it counts now — the
            // newline, if it ever comes, then reads as an empty line.
            if pos >= to, !carry.isEmpty, (try? JSONSerialization.jsonObject(with: carry)) != nil {
                parse(lines: carry)
                consumed += UInt64(carry.count)
            }
            return consumed
        }

        private func parse(lines block: Data) {
            var start = block.startIndex
            while start < block.endIndex {
                let end = block[start...].firstIndex(of: 0x0A) ?? block.endIndex
                let line = block[start..<end]
                start = end < block.endIndex ? block.index(after: end) : end
                // Only two kinds of line carry usage, and both name it outright; the rest — tool
                // output, prompts, progress — are most of the bytes and need no parse at all.
                guard line.count > 2,
                      line.range(of: TokenUsage.usageKey) != nil || line.range(of: TokenUsage.tokenCountKey) != nil
                else { continue }
                autoreleasepool { take(Data(line)) }
            }
        }

        private func take(_ ld: Data) {
            guard let o = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else { return }
            // Codex: token_count → cumulative total_token_usage (payload.info in newer builds).
            if let p = o["payload"] as? [String: Any], (p["type"] as? String) == "token_count" {
                let container = (p["info"] as? [String: Any]) ?? p
                if let tu = container["total_token_usage"] as? [String: Any] {
                    let newCum = max(0, TokenUsage.int(tu["input_tokens"]) - TokenUsage.int(tu["cached_input_tokens"]))
                        + TokenUsage.int(tu["output_tokens"])
                    if let t = TokenUsage.date(o["timestamp"]) { seq += 1; codex.append((t, newCum, seq)) }
                }
                return
            }
            // Claude: assistant usage → new = input + cache-writes + output (excl. cache reads).
            if (o["type"] as? String) == "assistant",
               let m = o["message"] as? [String: Any],
               let u = m["usage"] as? [String: Any] {
                let id = (m["id"] as? String) ?? (o["requestId"] as? String) ?? ""
                if !id.isEmpty { if seen.contains(id) { return }; seen.insert(id) }
                let inc = TokenUsage.int(u["input_tokens"]) + TokenUsage.int(u["cache_creation_input_tokens"])
                    + TokenUsage.int(u["output_tokens"])
                if let t = TokenUsage.date(o["timestamp"]) { seq += 1; claude.append((t, inc, seq)) }
            }
        }
    }

    fileprivate static let usageKey = Data("\"usage\"".utf8)
    fileprivate static let tokenCountKey = Data("\"token_count\"".utf8)

    private static var ledgers: [String: Ledger] = [:]
    private static let ledgersLock = NSLock()

    /// One ledger per transcript, kept for the transcripts asked about lately. A board holds a few
    /// dozen terminals; past that the least recently used goes, and is simply read again if asked.
    private static func ledger(for path: String) -> Ledger {
        ledgersLock.lock()
        defer { ledgersLock.unlock() }
        if let l = ledgers[path] { l.used = Date(); return l }
        if ledgers.count >= 64, let stale = ledgers.min(by: { $0.value.used < $1.value.used })?.key {
            ledgers.removeValue(forKey: stale)
        }
        let l = Ledger()
        ledgers[path] = l
        return l
    }

    /// Compact token count for labels: 512 · 4.2k · 58.8k · 1.2M.
    static func short(_ n: Int) -> String {
        let x = Double(n)
        if n >= 1_000_000 { return String(format: "%.1fM", x / 1_000_000) }
        if n >= 10_000    { return String(format: "%.0fk", x / 1_000) }
        if n >= 1_000     { return String(format: "%.1fk", x / 1_000) }
        return "\(n)"
    }

    // MARK: - Helpers

    fileprivate static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return 0
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    fileprivate static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }
}
