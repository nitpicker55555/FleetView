import Foundation

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

    static var sessionsDir: URL { FV.home.appendingPathComponent(".codex/sessions", isDirectory: true) }

    /// How far back a rollout can have been touched and still count as this terminal's live one.
    /// A session idle for longer than this is not what the terminal is writing now.
    private static let staleAfter: TimeInterval = 48 * 3600

    // MARK: - Which rollout

    /// A rollout's `cwd`, from the `session_meta` record at its head. Cached by path because it is
    /// fixed for the life of the file, and resolving a terminal must not re-read every candidate.
    private static var cwdCache: [String: String] = [:]
    private static let lock = NSLock()

    static func rolloutCwd(_ path: String) -> String? {
        lock.lock()
        if let c = cwdCache[path] { lock.unlock(); return c }
        lock.unlock()

        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? h.close() }
        // session_meta is the first record, but it is not small — it carries the whole system prompt
        // and runs to ~19 KB, so a fixed small read truncates the line and the parse silently fails.
        // Read in chunks until the line actually ends.
        var buf = Data()
        while buf.count < 1_048_576 {
            guard let chunk = try? h.read(upToCount: 65_536), !chunk.isEmpty else { break }
            buf.append(chunk)
            if buf.firstIndex(of: 0x0A) != nil { break }
        }
        guard let nl = buf.firstIndex(of: 0x0A) else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(
                with: buf.subdata(in: buf.startIndex..<nl))) as? [String: Any],
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String else { return nil }
        lock.lock(); cwdCache[path] = cwd; lock.unlock()
        return cwd
    }

    /// Rollouts touched recently enough to be live, newest first. Codex files them under
    /// `sessions/YYYY/MM/DD/`, so only the last few day-directories are worth walking.
    private static func recentRollouts() -> [(path: String, mtime: Date)] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-staleAfter)
        var out: [(String, Date)] = []
        // Walk day directories rather than the whole tree: there are thousands of rollouts and only
        // the last couple of days can hold a live one.
        guard let years = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
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
                        if t > cutoff { out.append((f.path, t)) }
                    }
                }
            }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    /// The rollout a Codex terminal in `cwd` is writing right now: the most recently touched one
    /// recorded against that directory, skipping any another terminal has already claimed.
    ///
    /// Two Codex terminals in the SAME directory cannot be told apart this way — the newest rollout
    /// is claimed by whoever asks first and the other falls through to the next. That is a real
    /// limit, but it beats the previous behaviour, where every Codex terminal was stuck on the file
    /// it was first guessed to own.
    static func currentRollout(cwd: String, excluding claimed: Set<String>) -> String? {
        guard !cwd.isEmpty else { return nil }
        for (path, _) in recentRollouts() where !claimed.contains(path) {
            if rolloutCwd(path) == cwd { return path }
        }
        return nil
    }

    // MARK: - What it is doing

    /// Whether a turn is in flight, from the last turn-boundary event in the rollout.
    /// nil when the file says nothing either way.
    static func isWorking(rollout path: String) -> Bool? {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
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
        return working
    }
}
