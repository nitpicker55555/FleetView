import Foundation

/// Where an agent CLI keeps its state, and the command that starts it.
///
/// `claude` and `codex` keep theirs in `~/.claude` and `~/.codex`. sub-pool's `sp-claude` and
/// `sp-codex` run the same two CLIs under a credential leased from a pool, and on the board they are
/// the same agents: same transcripts, same hooks, same `--resume`. What differs is where the CLI is
/// told to keep its state. The wrapper points `CLAUDE_CONFIG_DIR` / `CODEX_HOME` at a temp dir made
/// for that one session (`$TMPDIR/sp-claude-XXXXXXXX`, removed when it ends) whose entries are
/// symlinks into a persistent home under `~/.sub-pool`. Everything sub-pool-specific follows from
/// that:
///
/// - Settings and config are read from that home, so FleetView's hooks have to be there too
///   (`HookInstaller`). Without them an `sp-claude` card never reported a single event.
/// - A path the agent reports runs through the temp dir and dies with it, so it is renamed to where
///   the file really is before anything keeps it (`canonical`).
/// - Each home resumes only what is filed under it: `codex resume` cannot see an `sp-codex` rollout,
///   nor the other way round, so the folder decides the command. Where a folder is shared —
///   `~/.sub-pool/claude-home/projects` is a symlink to `~/.claude/projects` on this Mac — it no
///   longer says which CLI ran. The conversation's own record does, and failing that the card's
///   (`resuming`).
enum AgentHome: CaseIterable, Sendable {
    case claude, codex, subPoolClaude, subPoolCodex

    init(kind: AgentKind, subPool: Bool) {
        switch (kind, subPool) {
        case (.codex, false): self = .codex
        case (.codex, true):  self = .subPoolCodex
        case (_, false):      self = .claude
        case (_, true):       self = .subPoolClaude
        }
    }

    var kind: AgentKind { self == .codex || self == .subPoolCodex ? .codex : .claude }
    var viaSubPool: Bool { self == .subPoolClaude || self == .subPoolCodex }

    /// What is typed to start it.
    var command: String {
        switch self {
        case .claude:        return "claude"
        case .codex:         return "codex"
        case .subPoolClaude: return "sp-claude"
        case .subPoolCodex:  return "sp-codex"
        }
    }

    static var subPoolDir: URL { FV.home.appendingPathComponent(".sub-pool", isDirectory: true) }

    var dir: URL {
        switch self {
        case .claude:        return FV.home.appendingPathComponent(".claude", isDirectory: true)
        case .codex:         return FV.home.appendingPathComponent(".codex", isDirectory: true)
        case .subPoolClaude: return Self.subPoolDir.appendingPathComponent("claude-home", isDirectory: true)
        case .subPoolCodex:  return Self.subPoolDir.appendingPathComponent("codex-home", isDirectory: true)
        }
    }

    /// Only a home already in use is adapted to — FleetView never creates `~/.sub-pool`, the same
    /// way it never creates `~/.codex`.
    var exists: Bool { FileManager.default.fileExists(atPath: dir.path) }

    /// Where its conversations are filed: Claude's per-project slugs, Codex's date tree.
    var historyRoot: URL {
        dir.appendingPathComponent(kind == .codex ? "sessions" : "projects", isDirectory: true)
    }

    // MARK: - Where conversations are

    /// A folder conversations are filed in, and every home that files there.
    struct Root: Sendable {
        let url: URL
        let homes: [AgentHome]
    }

    /// Each folder holding `kind`'s conversations, once. The CLI's own comes first and is always
    /// listed, exactly as it was before sub-pool; sub-pool's only when it is there, under the path it
    /// resolves to. A link to the CLI's own folder is that folder — walked twice, every conversation
    /// in it would be indexed, counted and offered twice.
    static func roots(_ kind: AgentKind) -> [Root] {
        var out: [Root] = []
        for home in allCases where home.kind == kind {
            let url = home.viaSubPool ? home.historyRoot.resolvingSymlinksInPath() : home.historyRoot
            if home.viaSubPool, !FileManager.default.fileExists(atPath: url.path) { continue }
            let real = url.resolvingSymlinksInPath().path
            if let i = out.firstIndex(where: { $0.url.resolvingSymlinksInPath().path == real }) {
                out[i] = Root(url: out[i].url, homes: out[i].homes + [home])
            } else {
                out.append(Root(url: url, homes: [home]))
            }
        }
        return out
    }

    /// The homes `path` is filed under: one, two when they share the folder, none when it is under
    /// neither.
    static func homes(holding path: String) -> [AgentHome] {
        let kind = Self.kind(ofTranscript: path)
        guard kind != .unknown else { return [] }
        return roots(kind).first { path.hasPrefix($0.url.path + "/") }?.homes ?? []
    }

    /// Which agent wrote a transcript, from its path alone — no disk access, because this is asked of
    /// every hook event and on every status poll. A Codex rollout is named `rollout-…` wherever it is
    /// filed, which is what keeps this right for a sessions folder linked somewhere else.
    static func kind(ofTranscript path: String) -> AgentKind {
        if (path as NSString).lastPathComponent.hasPrefix("rollout-")
            || path.contains("/.codex/") || path.contains("/.sub-pool/codex-home/") {
            return .codex
        }
        if let s = sessionDir(in: path) { return s.home.kind }
        if path.contains("/.claude/") || path.contains("/.sub-pool/claude-home/") { return .claude }
        return .unknown
    }

    static func isCodex(_ path: String) -> Bool { kind(ofTranscript: path) == .codex }

    // MARK: - What an agent reported

    /// The home of the agent that reported `path`, as the hook saw it: sub-pool's when it came
    /// through a session's temp dir, else whichever home it names. This is what tells an
    /// `sp-claude` card from a `claude` one when both file into the same `projects` folder — the
    /// path the CLI *reports* still runs through the dir it was given. nil for a path naming neither.
    static func reporting(_ path: String) -> AgentHome? {
        if let s = sessionDir(in: path) { return s.home }
        switch kind(ofTranscript: path) {
        case .codex:   return path.contains("/.sub-pool/") ? .subPoolCodex : .codex
        case .claude:  return path.contains("/.sub-pool/") ? .subPoolClaude : .claude
        case .unknown: return nil
        }
    }

    /// A path an agent reported, named by where the file lives.
    ///
    /// Under sub-pool every path the agent reports runs through its session's temp dir —
    /// `/tmp/sp-claude-1a2b3c4d/projects/<slug>/<sid>.jsonl` — and that dir is deleted when the
    /// session ends, taking every path recorded from it along. The same file is reached through the
    /// home itself and through whatever the home links to: here `projects` links to
    /// `~/.claude/projects`, so this comes out as the very path plain `claude` would have reported.
    /// Any other path comes back unchanged.
    static func canonical(_ path: String) -> String {
        guard let s = sessionDir(in: path), let top = s.rest.first, !top.isEmpty else { return path }
        return ([resolvedTop(s.home, top)] + s.rest.dropFirst()).joined(separator: "/")
    }

    /// The sub-pool home a path's session dir stands in for, and the path's components below it.
    /// The dir is Python's `mkdtemp(prefix="sp-claude-")`: the prefix and eight characters from
    /// `[a-z0-9_]`, which is specific enough that a folder of the user's own will not pass for one.
    private static func sessionDir(in path: String) -> (home: AgentHome, rest: [String])? {
        guard path.contains("/sp-") else { return nil }   // the usual case, without splitting anything
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for (i, part) in parts.enumerated() {
            for home in [AgentHome.subPoolClaude, .subPoolCodex] {
                let prefix = "sp-\(home.kind.rawValue)-"
                guard part.hasPrefix(prefix), part.count == prefix.count + 8,
                      part.dropFirst(prefix.count).allSatisfy({ $0 == "_" || $0.isASCII && ($0.isLowercase || $0.isNumber) })
                else { continue }
                return (home, Array(parts[(i + 1)...]))
            }
        }
        return nil
    }

    /// `~/.sub-pool/<home>/<top>` with its links followed. Remembered once it exists: this sits on
    /// the hook-pointer read, which runs every second for every terminal, and the link it follows
    /// is set up once by hand.
    private static func resolvedTop(_ home: AgentHome, _ top: String) -> String {
        let key = home.command + "/" + top
        lock.lock()
        if let hit = tops[key] { lock.unlock(); return hit }
        lock.unlock()
        let url = home.dir.appendingPathComponent(top)
        guard FileManager.default.fileExists(atPath: url.path) else { return url.path }
        let real = url.resolvingSymlinksInPath().path
        lock.lock(); tops[key] = real; lock.unlock()
        return real
    }
    private static var tops: [String: String] = [:]
    private static let lock = NSLock()

    // MARK: - Which command

    /// The CLI that resumes `transcript`: the home it is filed under, when only one is.
    ///
    /// Where `claude` and `sp-claude` share the folder, a conversation that has ever been in
    /// `sp-claude` goes back to `sp-claude`. Sub-pool's prompt history names the session of every
    /// prompt typed into it, and that record belongs to the conversation, so it is asked before the
    /// card is (`subPool`): the card a resume starts from — the one the session tree hangs off, the
    /// last one a search hit was seen in — need not be the CLI the conversation ran under. On
    /// 2026-10-06 a conversation begun in `sp-claude` was opened from the tree as plain `claude`,
    /// which puts it on whatever account `~/.claude` is logged into, if any. Both only ever argue
    /// for `sp-claude`; with neither, it is plain `claude`. `forkedFrom` is the session a fork was
    /// cut from, whose record the fork inherits until it has prompts of its own.
    static func resuming(_ transcript: String?, kind: AgentKind, subPool: Bool?,
                         forkedFrom: String? = nil) -> AgentHome {
        let filedKind = transcript.map { Self.kind(ofTranscript: $0) } ?? .unknown
        let k = filedKind == .unknown ? kind : filedKind
        let filed = transcript.map { homes(holding: $0) } ?? []
        if filed.count == 1 { return filed[0] }
        let sessions = [transcript.map(sessionId(of:)), forkedFrom].compactMap { $0 }
        let sp = (k == .claude && sessions.contains(where: typedInSubPool)) || subPool == true
        let pick = AgentHome(kind: k, subPool: sp)
        return filed.isEmpty || filed.contains(pick) ? pick : filed[0]
    }

    private static func sessionId(of transcript: String) -> String {
        ((transcript as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private static func typedInSubPool(_ sid: String) -> Bool {
        guard UUID(uuidString: sid) != nil,
              let data = try? Data(contentsOf: subPoolClaude.dir.appendingPathComponent("history.jsonl"),
                                   options: .mappedIfSafe)
        else { return false }
        return data.range(of: Data("\"sessionId\":\"\(sid)\"".utf8)) != nil
    }

    /// The agent CLI a shell command line starts, if it starts one: `sp-claude`, `codex resume …`,
    /// `cd '…' && claude --resume …` (which is how FleetView itself types them). Only a word in
    /// command position counts, so `git commit -m "try codex"` starts nothing.
    static func launched(by line: String) -> AgentHome? {
        var atCommand = true
        for piece in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            var word = String(piece)
            if ["&&", "||", ";", "|", "&", "(", "{"].contains(word) { atCommand = true; continue }
            let endsCommand = word.hasSuffix(";")
            if endsCommand { word.removeLast() }
            if atCommand {
                if let home = allCases.first(where: { $0.command == (word as NSString).lastPathComponent }) {
                    return home
                }
                // `FOO=1 claude`, `exec codex`: the next word is still the command.
                let prefix = (word.contains("=") && !word.hasPrefix("="))
                    || ["exec", "command", "noglob", "nohup", "env", "time"].contains(word)
                if !prefix { atCommand = false }
            }
            if endsCommand { atCommand = true }
        }
        return nil
    }
}
