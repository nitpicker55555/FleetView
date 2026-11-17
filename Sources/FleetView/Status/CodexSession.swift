import Foundation
import Darwin

/// Works out what a Codex terminal is doing by reading its rollout, without depending on hooks.
///
/// Codex has a hook-trust gate: a `[[hooks.*]]` block in `config.toml` is silently skipped unless
/// the hooks have been trusted, and there is no error to notice. Verified by running the same
/// prompt twice — identical config, identical environment, and only `--dangerously-bypass-hook-trust`
/// made them fire. So FleetView never received a single Codex event: the terminal→session pointer
/// was never written, the recorded transcript stayed at whatever was first guessed, and the status
/// never left `idle`. A conversation opened from the web showed a rollout from days earlier while
/// the terminal was actively working.
///
/// Everything needed is in the rollout itself, so that is where it now comes from. This also fixes
/// sessions that are *already running* — nothing has to be restarted for it to take effect.
enum CodexSession {

    /// Every folder Codex files rollouts in: `~/.codex/sessions`, and sub-pool's when `sp-codex` is
    /// in use (see AgentHome).
    static var sessionRoots: [URL] { AgentHome.roots(.codex).map(\.url) }

    /// How far back a rollout can have been touched and still count as this terminal's live one.
    /// A session idle for longer than this is not what the terminal is writing now.
    private static let staleAfter: TimeInterval = 48 * 3600

    // MARK: - Which rollout

    /// A rollout's `cwd`, and whether it is a worker's, from the `session_meta` record at its head.
    /// Cached by path because both are fixed for the life of the file, and resolving a terminal must
    /// not re-read every candidate.
    ///
    /// Its own cache rather than `CodexTree.meta`'s, which the tree panel empties whenever a rollout
    /// appears — every few seconds during a multi-agent run — while this is asked once a second for
    /// every Codex terminal.
    private static var headCache: [String: (cwd: String, isWorker: Bool, typedInto: Bool)] = [:]
    private static let lock = NSLock()

    static func rolloutCwd(_ path: String) -> String? { rolloutHead(path)?.cwd }

    private static func rolloutHead(_ path: String) -> (cwd: String, isWorker: Bool, typedInto: Bool)? {
        lock.lock()
        if let c = headCache[path] { lock.unlock(); return c }
        lock.unlock()

        guard let m = CodexTree.meta(path) else { return nil }
        let head = (m.cwd, m.isWorker, isTUI(path))
        lock.lock(); headCache[path] = head; lock.unlock()
        return head
    }

    /// Was this rollout written by the interactive CLI — the only thing a terminal on the board
    /// runs? `codex exec` (`"source":"exec"`), the desktop app and workers file rollouts in the same
    /// folders and the same cwds, and code_sense's batch scripts start `exec` runs all day: a Codex
    /// card opened there was handed whichever of those had been written last as its conversation.
    /// Read from the head's first few kilobytes, where `source` sits ahead of the instructions; a
    /// head that does not say is taken as the CLI's, as older builds did not.
    private static func isTUI(_ path: String) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return true }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 8192),
              let r = data.range(of: Data(#""source":"#.utf8)) else { return true }
        return data[r.upperBound...].starts(with: Data(#""cli""#.utf8))
    }

    /// The last walk, and when it was taken. The scan stats every rollout under `~/.codex/sessions`
    /// — 2000 files here, ~26ms — and it was being repeated per Codex terminal per second, on the
    /// main actor. It is cached rather than pruned by date because a rollout opened a week ago and
    /// still being appended to is a live session, and pruning by day-directory would lose it.
    ///
    /// Ten seconds because of what this actually answers: *which* rollout a terminal is writing,
    /// which only changes when a new session starts. Whether that session is working right now is a
    /// separate read (`isWorking`) that is not cached this way. So the visible cost of the staleness
    /// is that a brand-new Codex session can take up to 10s to be attributed — while every existing
    /// one stays exact.
    ///
    /// One walk per sessions folder, so a card known to run one CLI never pays for the other's:
    /// sub-pool's folder held 7000 rollouts here against `~/.codex`'s 2400, and walking it took the
    /// scan from 9ms to 29ms.
    private static var rolloutScan: [String: (at: Date, list: [Recent])] = [:]
    private static let scanTTL: TimeInterval = 10.0

    /// A live-enough rollout, and the homes whose CLI could be writing it — two when `codex` and
    /// `sp-codex` share one folder.
    private struct Recent { let path: String; let mtime: Date; let homes: [AgentHome] }

    /// Rollouts touched recently enough to be live, newest first, from the folders `home` files
    /// into — every one of them when nil.
    private static func recentRollouts(home: AgentHome?) -> [Recent] {
        AgentHome.roots(.codex).filter { home.map($0.homes.contains) ?? true }
            .flatMap(recentRollouts(in:))
            .sorted { $0.mtime > $1.mtime }
    }

    /// Codex files rollouts under `sessions/YYYY/MM/DD/`.
    private static func recentRollouts(in root: AgentHome.Root) -> [Recent] {
        lock.lock()
        if let s = rolloutScan[root.url.path], Date().timeIntervalSince(s.at) < scanTTL {
            let cached = s.list; lock.unlock(); return cached
        }
        lock.unlock()
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-staleAfter)
        var out: [Recent] = []
        // Walk day directories rather than the whole tree: there are thousands of rollouts and only
        // the last couple of days can hold a live one.
        guard let years = try? fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil)
        else { return [] }
        for y in years {
            guard let months = try? fm.contentsOfDirectory(at: y, includingPropertiesForKeys: nil) else { continue }
            for m in months {
                guard let days = try? fm.contentsOfDirectory(at: m, includingPropertiesForKeys: nil) else { continue }
                for d in days {
                    guard let files = try? fm.contentsOfDirectory(
                        at: d, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                    for f in files where f.pathExtension == "jsonl" {
                        let t = (try? f.resourceValues(forKeys: [.contentModificationDateKey])
                            .contentModificationDate) ?? .distantPast
                        if t > cutoff { out.append(Recent(path: f.path, mtime: t, homes: root.homes)) }
                    }
                }
            }
        }
        lock.lock(); rolloutScan[root.url.path] = (Date(), out); lock.unlock()
        return out
    }

    /// The rollout a Codex terminal in `cwd` is writing right now: the most recently touched one
    /// recorded against that directory, skipping any another terminal has already claimed.
    ///
    /// Two Codex terminals in the SAME directory cannot be told apart this way — the newest rollout
    /// is claimed by whoever asks first and the other falls through to the next. That is a real
    /// limit, but it beats the previous behaviour, where every Codex terminal was stuck on the file
    /// it was first guessed to own.
    ///
    /// `home` narrows it to what that CLI can be writing — a `codex` and an `sp-codex` terminal in
    /// one folder file into different places, and neither can be writing the other's rollout. nil
    /// when the card has not said which it runs.
    ///
    /// `since`, when the terminal's Codex is known to have started then: only a rollout written
    /// to after that can be the one it is writing. Without it a Codex opened a moment ago — nothing
    /// said yet, so no rollout of its own — was handed the newest one left in its folder, some other
    /// conversation, and the web chat showed it as this card's.
    static func currentRollout(cwd: String, excluding claimed: Set<String>,
                               home: AgentHome? = nil, since: Date? = nil) -> String? {
        guard !cwd.isEmpty else { return nil }
        for r in recentRollouts(home: home) where !claimed.contains(r.path) {
            if let since, r.mtime < since { break }        // newest first: the rest are older still
            let path = r.path
            // Never a worker. Workers share the cwd of the conversation that spawned them, are
            // written to constantly while a run is going and are claimed by no terminal, so they
            // always won this — and a Codex terminal idle in that directory took a busy worker's
            // turn for its own and showed "working" until the whole run was over.
            guard let head = rolloutHead(path), !head.isWorker, head.typedInto, head.cwd == cwd else { continue }
            return path
        }
        return nil
    }

    /// When a file was last written, for telling a conversation that went on after its terminal's
    /// Codex started from one that ended before.
    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - What it is doing

    /// Whether a turn is in flight, from the last turn-boundary event in the rollout.
    /// nil when the file says nothing either way.
    /// Last verdict per rollout, keyed by the file's size. Polled once a second, this read is
    /// 256KB plus a JSON parse of every line in it — and an idle terminal's rollout does not change
    /// between polls, so the answer cannot either. The size is the whole test: a rollout is only
    /// ever appended to, so same size ⇒ same last turn-boundary record.
    private static var workingCache: [String: (size: UInt64, verdict: Bool?)] = [:]

    static func isWorking(rollout path: String) -> Bool? {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        lock.lock()
        if let c = workingCache[path], c.size == size { let v = c.verdict; lock.unlock(); return v }
        lock.unlock()
        // A turn boundary is written frequently; the tail is always enough and keeps this cheap
        // enough to poll.
        let window: UInt64 = 256_000
        let start = size > window ? size - window : 0
        try? h.seek(toOffset: start)
        // Drop the partial first line as BYTES before decoding: the window starts at an arbitrary
        // offset, and one split multi-byte character makes String(data:encoding:) return nil for
        // the whole block rather than for the bad part.
        guard var data = try? h.readToEnd() else { return nil }
        if start > 0, let nl = data.firstIndex(of: 0x0A) {
            data = data.subdata(in: data.index(after: nl)..<data.endIndex)
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var working: Bool?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  (obj["type"] as? String) == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  let kind = payload["type"] as? String else { continue }
            switch kind {
            case "task_started": working = true
            case "task_complete", "turn_aborted": working = false
            default: continue
            }
        }
        lock.lock(); workingCache[path] = (size, working); lock.unlock()
        return working
    }

    // MARK: - Whose rollout

    /// Whether a process in tmux session `sessionName` holds `path` open. The Codex CLI keeps its
    /// rollout open for as long as the conversation runs (fd 48 on the card that showed this), so
    /// this says whose a rollout is outright — where "the newest unclaimed one in the folder" only
    /// guesses, and is the only thing left after FleetView restarts under a Codex already running.
    ///
    /// Asked once per card and path (answers are kept): it spawns tmux and reads file tables, and it
    /// is only needed for a rollout the card has not been bound to yet.
    static func heldOpen(_ path: String, tmuxPath: String, sessionName: String, card: UUID) -> Bool {
        let key = "\(card)|\(path)"
        lock.lock()
        if let known = heldCache[key] { lock.unlock(); return known }
        lock.unlock()
        let held = panePid(tmuxPath: tmuxPath, sessionName: sessionName).map { pane -> Bool in
            let sid = getsid(pane)
            guard sid > 0, sid != getsid(0) else { return false }
            let target = (path as NSString).resolvingSymlinksInPath
            return ProcTable.read().filter { $0.sid == sid }
                .contains { openFiles($0.pid).contains { ($0 as NSString).resolvingSymlinksInPath == target } }
        } ?? false
        lock.lock(); heldCache[key] = held; lock.unlock()
        return held
    }
    private static var heldCache: [String: Bool] = [:]

    private static func panePid(tmuxPath: String, sessionName: String) -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxPath)
        p.arguments = ["-L", RemoteServer.socket, "list-panes", "-t", sessionName, "-F", "#{pane_pid}"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline).first.flatMap { pid_t($0) }
    }

    /// The paths of the regular files `pid` has open (libproc; this user's processes only).
    private static func openFiles(_ pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let got = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard got > 0 else { return [] }
        var out: [String] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let n = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                   Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard n == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { out.append(path) }
        }
        return out
    }
}
