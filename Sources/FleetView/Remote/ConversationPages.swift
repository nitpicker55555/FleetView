import Foundation

/// One prompt in `GET /conversation?prompts=1`.
struct ConvPrompt: Codable {
    let at: Double
    let text: String
    let ts: String?
}

/// One transcript line, kept small: where it is, and the few fields that decide whether it belongs
/// to the conversation being shown. What ConversationPages indexes a whole file into, and what
/// `activePath` walks — for the polled tail as much as for the pages before it, so the two agree on
/// which branch is the conversation.
struct TranscriptLink {
    let at: Int
    var length: Int = 0
    var uuid: String? = nil
    var parent: String? = nil
    var sidechain = false
    /// A `compact_boundary`: no `parentUuid`, and the conversation it continues named in
    /// `logicalParent`, with the records the compaction kept verbatim in `preserved`.
    var boundary = false
    var logicalParent: String? = nil
    var preserved: [String] = []
    var leaf: String? = nil          // a `last-prompt` line's leafUuid
    /// A prompt someone actually typed, clipped — what a terminal's own last prompt is matched
    /// against to pick its branch when several terminals share one session.
    var prompt: String? = nil
    /// What the web chat's prompt wheel lists for this line: a prompt as typed (an injected one —
    /// a slash command's wrapper, an interruption, a reminder — is not), or one typed mid-turn and
    /// written as a `queued_command`. With its time.
    var asked: String? = nil
    var ts: String? = nil

    /// A line with no tree to place it in (Codex, or one that is not JSON): its position only.
    init(at: Int, length: Int) {
        self.at = at
        self.length = length
    }

    init(_ r: [String: Any], at: Int, length: Int = 0) {
        self.at = at
        self.length = length
        uuid = r["uuid"] as? String
        parent = r["parentUuid"] as? String
        sidechain = (r["isSidechain"] as? Bool) ?? false
        let type = r["type"] as? String
        if type == "last-prompt" { leaf = r["leafUuid"] as? String }
        if type == "attachment", !sidechain, let a = r["attachment"] as? [String: Any],
           (a["type"] as? String) == "queued_command", (a["commandMode"] as? String) == "prompt" {
            let text = (a["prompt"] as? String) ?? (a["prompt"] as? [[String: Any]])?
                .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            asked = text.flatMap(PromptText.clean).map { String($0.prefix(400)) }
            ts = r["timestamp"] as? String
            return
        }
        if (r["subtype"] as? String) == "compact_boundary" {
            boundary = true
            logicalParent = r["logicalParentUuid"] as? String
            if let kept = (r["compactMetadata"] as? [String: Any])?["preservedMessages"] as? [String: Any] {
                preserved = (kept["allUuids"] as? [String]) ?? (kept["uuids"] as? [String]) ?? []
            }
        }
        // What Claude itself writes into the user role is skipped, or the live branch stops matching
        // the prompt that started it: a background task finishing (`promptSource: "system"`, or only
        // its wrapper in older builds), a compaction's summary, a meta record.
        guard type == "user", !sidechain,
              (r["isMeta"] as? Bool) != true,
              (r["isCompactSummary"] as? Bool) != true,
              (r["promptSource"] as? String) != "system",
              let msg = r["message"] as? [String: Any] else { return }
        var text: String?
        if let s = msg["content"] as? String, !Conversation.trim(s).isEmpty { text = s }
        if text == nil, let blocks = msg["content"] as? [[String: Any]] {
            text = blocks.lazy.filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }.first { !Conversation.trim($0).isEmpty }
        }
        if let text, !text.hasPrefix("<task-notification") { prompt = String(text.prefix(400)) }
        asked = text.flatMap(PromptText.clean).map { String($0.prefix(400)) }
        if asked != nil { ts = r["timestamp"] as? String }
    }
}

/// The conversation before what the web chat polls: `GET /conversation?id=&before=<at>` answers
/// the messages just before position `at`, oldest first, and whether there are more.
///
/// The poll reads the tail of the transcript, and a long session is far more than any tail — this
/// one's own transcript reached 151 MB, a Codex rollout here 725 MB — so the rest has to come in
/// pages, read where they are rather than by parsing the file. Each file is indexed once into
/// `TranscriptLink`s (a line's position and its tree links; ~0.25 s per 150 MB for Claude, a newline
/// scan for Codex) and extended as it grows; a page then parses only its own few hundred lines.
///
/// Positions are byte offsets, which is what makes the paging exact: a line's offset never changes
/// as the file grows, so the page's "before the oldest message I have" means the same thing on every
/// request, and the poll's window can slide on without the two ever overlapping or leaving a gap.
enum ConversationPages {
    private struct Indexed {
        let inode: UInt64
        var upTo: Int                 // bytes indexed: everything before the last complete line's end
        var recs: [TranscriptLink]
        var used: Date
    }
    private static var cache: [String: Indexed] = [:]
    private static let lock = NSLock()

    /// Whether the transcript continues one before it — a Codex fork or rewind segment, whose own
    /// file starts where its `history_base` ends.
    static func hasBase(_ path: String) -> Bool {
        AgentHome.isCodex(path) && CodexTree.meta(path)?.base != nil
    }

    /// Is a Claude line part of the conversation whose records are `active`? Sidechain records are
    /// kept whatever their branch — a subagent hangs off its own chain — and so is a line with no
    /// uuid, which is never a message anyway.
    static func onPath(_ obj: [String: Any], _ active: Set<String>) -> Bool {
        guard let uuid = obj["uuid"] as? String else { return true }
        return (obj["isSidechain"] as? Bool) == true || active.contains(uuid)
    }

    private static func onPath(_ r: TranscriptLink, _ active: Set<String>?) -> Bool {
        guard let active, let uuid = r.uuid else { return true }
        return r.sidechain || active.contains(uuid)
    }

    /// The uuids on the session's *active* branch, walking `parentUuid` back from the current tip —
    /// and on through every compaction, into the conversation it continues. nil when the lines have
    /// no tree at all (Codex), so there is nothing to filter.
    ///
    /// The tip: the branch whose latest prompt is this terminal's own (several terminals resuming
    /// one session share its file, each on its own branch); otherwise the `last-prompt` record's
    /// leaf, descended to the current end of that branch (replies made after it hang below), or the
    /// newest record.
    ///
    /// A compaction starts a fresh chain: its boundary has no `parentUuid` and names what it
    /// continues in `logicalParentUuid`. The walk used to stop there, so a compacted session showed
    /// only what came after its last compaction — a few messages, with hours of conversation in
    /// the same file above them. Where the walk goes next is TreeGraph's `continuesFrom`: the
    /// logical parent when it lies above the boundary, else the newest of the records the
    /// compaction kept that does (Claude Code 2.1.280 points the link at a kept record it had not
    /// flushed yet, written *below* the boundary — followed, that leads back into the compacted
    /// half).
    static func activePath(_ recs: [TranscriptLink], ownPrompt: String, branches: inout Int) -> Set<String>? {
        var parent: [String: String] = [:]
        var children: [String: [String]] = [:]     // in file order ⇒ last child is the newest
        var index: [String: Int] = [:]
        var order: [String] = []
        var leaf: String?
        // Records a compaction carried into the session it started stay where they were in the old
        // chain, and the last one has no child on disk: it looks like the tip of an abandoned branch
        // and is not one. Taken for a tip, it froze the chat at the moment of the compaction.
        var carried = Set<String>()
        for (i, r) in recs.enumerated() {
            if let l = r.leaf { leaf = l }
            if r.boundary {
                if let l = r.logicalParent { carried.insert(l) }
                carried.formUnion(r.preserved)
            }
            guard let u = r.uuid else { continue }
            index[u] = i
            order.append(u)
            if let p = r.parent {
                parent[u] = p
                children[p, default: []].append(u)
            }
        }
        guard !order.isEmpty else { return nil }
        let leaves = order.filter { children[$0] == nil && !carried.contains($0) }
        branches = children.values.filter { $0.count > 1 }.count

        /// The latest real prompt on the branch ending at `leaf` — raw parents only: the question is
        /// which branch is this terminal's, and that is decided after the last compaction.
        func latestPrompt(_ leaf: String) -> String? {
            var u: String? = leaf
            var seen = Set<String>()
            while let cur = u, seen.insert(cur).inserted {
                if let i = index[cur], let p = recs[i].prompt { return p }
                u = parent[cur]
            }
            return nil
        }
        var tip: String?
        let want = Conversation.normalized(ownPrompt)
        if !want.isEmpty {
            tip = leaves.reversed().first { l in
                latestPrompt(l).map { Conversation.matches(Conversation.normalized($0), want) } ?? false
            }
        }
        if tip == nil {
            tip = leaf.flatMap { index[$0] != nil ? $0 : nil } ?? order.last
            var visited = Set<String>()
            while let u = tip, let kids = children[u], let next = kids.last, visited.insert(u).inserted {
                tip = next
            }
        }

        /// Is `record` below `boundary` — written in the compacted session rather than before it?
        func isBelow(_ record: String, _ boundary: String) -> Bool {
            var cur: String? = record
            var seen = Set<String>()
            while let c = cur, seen.insert(c).inserted {
                if c == boundary { return true }
                cur = parent[c]
            }
            return false
        }
        var path = Set<String>()
        var cur = tip
        while let u = cur, path.insert(u).inserted {
            if let p = parent[u] {
                cur = p
            } else if let i = index[u], recs[i].boundary {
                let r = recs[i]
                cur = ([r.logicalParent].compactMap { $0 } + r.preserved.reversed())
                    .first { index[$0] != nil && !isBelow($0, u) }
            } else {
                cur = nil
            }
        }
        return path.isEmpty ? nil : path
    }

    /// Every complete line of `path`, slimmed — extended rather than rebuilt while the file has only
    /// grown. A Codex rollout has no tree, so its lines are only found, not parsed: a 725 MB rollout
    /// is a newline scan. Read in chunks rather than mapped: a mapping the scan has walked stays
    /// resident, and the 725 MB one put the process at 1.3 GB.
    private static func index(_ path: String, codex: Bool) -> [TranscriptLink]? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = Int((try? h.seekToEnd()) ?? 0)
        let inode = ((try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber]
                     as? NSNumber)?.uint64Value ?? 0
        lock.lock()
        var e = cache[path]
        lock.unlock()
        // Rewritten (a new inode) or shorter than what was indexed: start over.
        if e == nil || e!.inode != inode || e!.upTo > size {
            e = Indexed(inode: inode, upTo: 0, recs: [], used: Date())
        }
        var entry = e!
        var chunk = 8 << 20
        // Each chunk in its own pool: FileHandle's reads are autoreleased, and left to the request's
        // pool a 725 MB scan held all 725 MB until it returned.
        scan: while entry.upTo < size {
          let more: Bool = autoreleasepool {
            try? h.seek(toOffset: UInt64(entry.upTo))
            guard let data = try? h.read(upToCount: chunk), !data.isEmpty else { return false }
            var consumed = 0
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var start = 0
                while start < raw.count, let hit = memchr(base + start, 0x0A, raw.count - start) {
                    let nl = base.distance(to: UnsafeRawPointer(hit))
                    if nl > start {
                        let len = nl - start, at = entry.upTo + start
                        if codex {
                            entry.recs.append(TranscriptLink(at: at, length: len))
                        } else {
                            // Drained per line: JSONSerialization's objects are autoreleased, and a
                            // pool that drains only when the request ends holds the whole file.
                            autoreleasepool {
                                if let obj = (try? JSONSerialization.jsonObject(
                                        with: Conversation.shrunk(Data(bytes: base + start, count: len)))) as? [String: Any] {
                                    entry.recs.append(TranscriptLink(obj, at: at, length: len))
                                }
                            }
                        }
                    }
                    start = nl + 1
                }
                consumed = start
            }
            // No newline in a whole chunk: one line longer than it. Read more at once.
            if consumed == 0 {
                if data.count < chunk { return false }    // the last line, still being written
                chunk *= 2
                return true
            }
            entry.upTo += consumed                 // a last line still being written is read next time
            return true
          }
          if !more { break scan }
        }
        entry.used = Date()
        lock.lock()
        cache[path] = entry
        // A few chats paged at once is the most there is; past that, drop the stalest.
        if cache.count > 4, let stale = cache.min(by: { $0.value.used < $1.value.used })?.key {
            cache[stale] = nil
        }
        lock.unlock()
        return entry.recs
    }

    /// One file of the conversation: its lines, and what turns an offset in it into a position.
    private struct Segment {
        let path: String
        let recs: [TranscriptLink]
        let shift: Int
        var cut: Int? = nil           // a history_base's share of its file ends here
    }

    /// The files the conversation is made of, oldest first. A Claude session is one file. A Codex
    /// fork or rewind segment holds only what came after it and names the rest in `history_base` —
    /// the parent rollout and the byte its share ends at — so the chain is followed to its start,
    /// each base cut where the reference says. Positions in a base are negative, counted back from
    /// its cut: the whole chain then reads as one line of numbers, oldest lowest.
    private static func segments(_ path: String) -> [Segment] {
        let codex = AgentHome.isCodex(path)
        guard let own = index(path, codex: codex) else { return [] }
        var out = [Segment(path: path, recs: own, shift: 0)]
        guard codex else { return out }
        var meta = CodexTree.meta(path)
        var shift = 0
        var seen: Set<String> = [path]
        while let b = meta?.base,
              let p = CodexTree.rolloutPath(ofRollout: b.rollout, roots: CodexSession.sessionRoots),
              seen.insert(p).inserted, let recs = index(p, codex: true) {
            let cut = b.endByte ?? ((recs.last.map { $0.at + $0.length + 1 }) ?? 0)
            shift -= cut
            out.insert(Segment(path: p, recs: recs.filter { $0.at < cut }, shift: shift, cut: cut), at: 0)
            meta = CodexTree.meta(p)
        }
        return out
    }

    /// Every prompt of the conversation, oldest first, at the position of the message it is in the
    /// chat — the web's prompt wheel, which jumps to one by loading pages back to its position.
    /// Claude's come from the index, on the branch the chat shows; Codex's from CodexTree's turns,
    /// which are the same lines (a turn's `byte` is its line's offset), down the history_base chain.
    static func prompts(path: String, ownPrompt: String) -> [ConvPrompt] {
        let segs = segments(path)
        guard let own = segs.last else { return [] }
        if AgentHome.isCodex(path) {
            return segs.flatMap { seg in
                CodexTree.turns(of: seg.path).filter { t in seg.cut.map { t.byte < $0 } ?? true }
                    .map { ConvPrompt(at: Double($0.byte + seg.shift), text: $0.text, ts: $0.ts) }
            }
        }
        var branches = 0
        let active = activePath(own.recs, ownPrompt: ownPrompt, branches: &branches)
        return own.recs.compactMap { r in
            guard let text = r.asked, !r.sidechain, onPath(r, active) else { return nil }
            return ConvPrompt(at: Double(r.at), text: text, ts: r.ts)
        }
    }

    /// Image `n` of the line at position `at` (see ConvImage), decoded. The line is read whole and
    /// parsed without `shrunk`: the base64 is the one string here that is wanted in full.
    static func image(path: String, at: Int, n: Int) -> (data: Data, mime: String)? {
        var file = path, offset = at
        if at < 0 {                                   // inside a Codex history_base
            guard let seg = segments(path).first(where: { at >= $0.shift && at < $0.shift + ($0.cut ?? .max) })
            else { return nil }
            file = seg.path; offset = at - seg.shift
        }
        guard let h = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(offset))) != nil else { return nil }
        var line = Data()
        while line.count < (256 << 20) {
            guard let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            if let nl = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[chunk.startIndex..<nl]); break
            }
            line.append(chunk)
        }
        return autoreleasepool { () -> (data: Data, mime: String)? in
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
            let blocks = Conversation.imageBlocks(obj)
            guard n >= 0, n < blocks.count, let b64 = blocks[n].data,
                  let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
            let mime = blocks[n].mime.flatMap { $0.hasPrefix("image/") ? $0 : nil } ?? "image/png"
            return (data, mime)
        }
    }

    /// The `limit` messages before position `before`, oldest first.
    static func page(path: String, before: Double, limit: Int, cwd: String, ownPrompt: String) -> ConvResult {
        let segs = segments(path)
        guard let own = segs.last else { return ConvResult(messages: [], info: ConvInfo()) }
        var branches = 0
        // Over the whole file, the same walk the tail makes: through every compaction.
        let active = activePath(own.recs, ownPrompt: ownPrompt, branches: &branches)
        // The conversation's lines in order: (segment, line).
        var lines: [(seg: Int, rec: TranscriptLink)] = []
        for (s, seg) in segs.enumerated() {
            for r in seg.recs where s < segs.count - 1 || onPath(r, active) { lines.append((s, r)) }
        }
        let end = lines.firstIndex { Double($0.rec.at + segs[$0.seg].shift) >= before } ?? lines.count

        let handles = segs.map { FileHandle(forReadingAtPath: $0.path) }
        defer { for h in handles { try? h?.close() } }
        func read(_ range: Range<Int>) -> [Conversation.Line] {
            lines[range].compactMap { l in
                autoreleasepool {
                    let seg = segs[l.seg]
                    guard let h = handles[l.seg],
                          (try? h.seek(toOffset: UInt64(l.rec.at))) != nil,
                          let data = try? h.read(upToCount: l.rec.length), data.count == l.rec.length,
                          let obj = (try? JSONSerialization.jsonObject(with: Conversation.shrunk(data))) as? [String: Any]
                    else { return nil }
                    return Conversation.Line(at: l.rec.at + seg.shift, obj: obj)
                }
            }
        }
        // Lines after the page, for the results of the calls at its end. A result is written right
        // after its call, so a short look is enough.
        let after = read(end..<min(lines.count, end + 200))
        // How many lines make `limit` messages is not known until they are read: a tool result is
        // a line of its own and no message, a reply can be several. Read a batch back from the end,
        // and twice as many again while that is short.
        var batch = max(limit * 2, 64)
        var start = end
        var msgs: [ConvMsg] = []
        repeat {
            start = max(0, end - batch)
            msgs = Conversation.build(read(start..<end), path: path, cwd: cwd, ownPrompt: ownPrompt,
                                      live: false, lookahead: after).messages
                .filter { ($0.at ?? 0) < before }
            batch *= 2
        } while msgs.count < limit && start > 0
        let cut = msgs.count > limit
        if cut { msgs = Array(msgs.suffix(limit)) }
        var info = ConvInfo()
        info.more = cut || start > 0
        info.branches = branches
        return ConvResult(messages: msgs, info: info)
    }
}
