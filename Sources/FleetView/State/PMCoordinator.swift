import Foundation
import FleetViewAudit

/// Where the PM keeps everything, outside the repo like the rest of FleetView's runtime state.
///
/// One fixed folder, so the PM's records are always in the same place whichever conversation it is
/// on: its role (`CLAUDE.md`, which Claude reads because this is the PM's working directory), its own
/// notes (`ledger/`), the cards FleetView saw it start (`roster.json`), every status digest it was
/// sent (`inbox.jsonl`), each project's side-question thread (`asks/`), and a copy of each of its
/// transcripts (`sessions/`). The copy is there because the originals are not safe where Claude
/// keeps them: a 30-day cleanup took ~3,600 of them on 2026-10-06.
enum PMPaths {
    static var home: URL { FV.supportDir.appendingPathComponent("pm", isDirectory: true) }
    static var roster: URL { home.appendingPathComponent("roster.json") }
    static var role: URL { home.appendingPathComponent("CLAUDE.md") }
    static var ledger: URL { home.appendingPathComponent("ledger", isDirectory: true) }
    static var sessions: URL { home.appendingPathComponent("sessions", isDirectory: true) }
    static var asks: URL { home.appendingPathComponent("asks", isDirectory: true) }
    static var threads: URL { asks.appendingPathComponent("threads.json") }
    static var inbox: URL { home.appendingPathComponent("inbox.jsonl") }

    /// What a side question may use: reading, and `project-manager`'s read-only commands. The fork
    /// runs in `dontAsk` mode, so anything not on this list is refused rather than asked about —
    /// a side question is for looking, and the main line is where things get done.
    static let askTools = [
        "Read", "Grep", "Glob",
        "Bash(project-manager ls:*)", "Bash(project-manager show:*)", "Bash(project-manager tail:*)",
        "Bash(project-manager log:*)", "Bash(project-manager check:*)", "Bash(project-manager commits:*)",
        "Bash(project-manager writers:*)", "Bash(project-manager repo:*)", "Bash(project-manager audit:*)",
        "Bash(project-manager projects:*)", "Bash(project-manager history:*)",
        "Bash(project-manager session:*)", "Bash(project-manager search:*)",
        "Bash(project-manager memory:*)", "Bash(project-manager whoami:*)",
        "Bash(git log:*)", "Bash(git show:*)", "Bash(git status:*)",
    ]
}

/// FleetView's project manager: one Claude card that is always there, beside the board, that turns
/// a request into a project and a team of other cards, keeps track of them, and does none of the
/// work itself (see docs/design/2026-11-11-pm-card.md).
///
/// FleetView's part is what a prompt cannot do on its own:
/// - keep the card alive across relaunches, resuming its own conversation;
/// - know which cards it started (the `/new` it called carries its id) and tell it when one of them
///   finishes a turn, needs someone or stops — batched, and only while it is idle, so a digest never
///   lands in the middle of its turn;
/// - run side questions: a thread per project, forked once from the PM's conversation and resumed for
///   each follow-up, read-only, written to a file the main line can read.
@MainActor
final class PMCoordinator: ObservableObject {
    /// The command a fresh PM starts with — bypass, like the rest of the fleet (the user's call,
    /// 2026-11-11). A relaunch resumes instead, and `resumeCommand` keeps the same flag.
    static let launchCommand = "claude --dangerously-skip-permissions"
    static let cardName = "PM"

    /// Off on a headless Mac unless asked for: the Mac mini is shared, and a manager nobody looks at
    /// is a Claude session spending tokens on digests.
    static var enabled: Bool {
        !Headless.active || ProcessInfo.processInfo.environment["FV_PM"] == "1"
    }

    weak var app: AppState?
    /// The PM's card, once there is one.
    @Published private(set) var terminalId: UUID?

    private var roster = Roster()
    private var threads: [String: AskThread] = [:]

    // MARK: Lifecycle

    func start(_ app: AppState) {
        self.app = app
        guard Self.enabled else { return }
        Self.prepareHome()
        roster = Roster.load()
        threads = AskThread.loadAll()
        // A question that was being answered when FleetView quit has lost its process.
        for (k, var th) in threads {
            var changed = false
            for i in th.turns.indices where th.turns[i].a == nil && th.turns[i].failed != true {
                th.turns[i].failed = true
                th.turns[i].a = "（FleetView 重启时这个问题还没答完）"
                changed = true
            }
            if changed { threads[k] = th }
        }
        AskThread.saveAll(threads)
        ensureRunning()
        // Retries what a busy PM could not take, and notices a PM that was closed.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private var tickTimer: Timer?

    /// Make sure the PM has a card and that something is running in it. Called at launch and by the
    /// dock's start button; a card the user removed is made again here.
    func ensureRunning() {
        guard Self.enabled, let app else { return }
        let projectId = app.ensureProject(path: PMPaths.home.path, name: Self.cardName)
        var id = roster.pm.flatMap(UUID.init(uuidString:))
        if let i = id, !app.terminals.contains(where: { $0.id == i }) { id = nil }
        if id == nil {
            guard let t = app.makeCardWithoutWindow(projectId: projectId, name: Self.cardName,
                                                    cwd: PMPaths.home.path) else { return }
            id = t.id
            roster.pm = t.id.uuidString
            roster.save()
            FV.log("pm: made the PM card \(t.id.uuidString)")
        }
        terminalId = id
        guard let id else { return }
        if !app.hasHost(id) { app.startWithoutWindow(id, freshCommand: Self.launchCommand) }
    }

    func isPM(_ id: UUID) -> Bool { id == terminalId }
    func isPMProject(_ p: Project) -> Bool { p.path == PMPaths.home.path }
    func isWorker(_ id: UUID) -> Bool { roster.workers[id.uuidString] != nil }
    var workerIds: Set<String> { Set(roster.workers.keys) }

    // MARK: Workers

    /// A card `/new` just made: the PM's if the call came from the PM's own card.
    func noteCreated(_ t: TerminalSession) {
        guard let pm = terminalId,
              case .string(let caller)? = AuditContext.actor.extra["caller.terminal.id"],
              caller.uppercased() == pm.uuidString else { return }
        roster.workers[t.id.uuidString] = .init(since: Date(), name: t.name,
                                                project: app?.project(t.projectId)?.name)
        roster.save()
        FV.log("pm: \(t.name) (\(t.id.uuidString.prefix(8))) is the PM's")
    }

    /// One worker's change, as the digest says it.
    struct Event: Codable {
        let at: Date
        let id: String
        let name: String
        let project: String
        let what: String
    }
    private var pending: [String: Event] = [:]
    private var flushWork: DispatchWorkItem?
    private var lastDigest = Date.distantPast
    /// A digest at most this often: a team finishing one after another is one message, not five.
    static let digestSpacing: TimeInterval = 45

    /// Called from `enterStatus`, the one place a status changes.
    func statusChanged(_ t: TerminalSession, from old: TermStatus, to new: TermStatus) {
        guard old != new, terminalId != nil else { return }
        if t.id == terminalId {
            // It has come back to its prompt: whatever waited for that can go now.
            if new == .idle, !pending.isEmpty { scheduleFlush(after: 3) }
            return
        }
        guard let w = roster.workers[t.id.uuidString] else { return }
        let what: String
        switch (old, new) {
        case (.working, .idle):                        what = "完成一轮，回到等待输入"
        case (_, .needsYou):                           what = "停在一个要人回答的提示上"
        case (.working, .exited), (.idle, .exited), (.needsYou, .exited): what = "进程已退出"
        case (.working, .closed), (.idle, .closed), (.needsYou, .closed): what = "卡片被关闭"
        default: return
        }
        let ev = Event(at: Date(), id: t.id.uuidString, name: t.name,
                       project: app?.project(t.projectId)?.name ?? w.project ?? "—", what: what)
        pending[ev.id] = ev                           // the latest word per card
        Self.appendLine(PMPaths.inbox, ["kind": "event", "at": ISO8601DateFormatter().string(from: ev.at),
                                        "id": ev.id, "name": ev.name, "project": ev.project, "what": what])
        scheduleFlush(after: 20)
    }

    private func scheduleFlush(after delay: TimeInterval) {
        guard flushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flushWork = nil
            self?.flush()
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Hand the PM what has piled up — only when it is sitting at its prompt. A digest typed into a
    /// turn would be queued behind it at best and read as an interruption at worst; one typed into a
    /// bare shell (the PM's claude not running) would be a command.
    func flush() {
        guard let app, let pm = terminalId else { return }
        if !app.hasHost(pm) && Self.enabled {
            // Its session went away — closed from the board, or the shell exited. A fixed card comes
            // back; the next launch would bring it back anyway.
            if let t = app.terminals.first(where: { $0.id == pm }), t.status == .closed || t.status == .exited {
                ensureRunning()
            }
            return
        }
        // Cards removed since they were recorded are nobody's now.
        let live = Set(app.terminals.map(\.id.uuidString))
        if roster.workers.keys.contains(where: { !live.contains($0) }) {
            roster.workers = roster.workers.filter { live.contains($0.key) }
            roster.save()
        }
        guard !pending.isEmpty else { return }
        guard let t = app.terminals.first(where: { $0.id == pm }), t.status == .idle else { return }
        let wait = Self.digestSpacing - Date().timeIntervalSince(lastDigest)
        if wait > 0 { scheduleFlush(after: wait); return }
        let events = pending.values.sorted { $0.at < $1.at }
        pending.removeAll()
        let text = digest(events)
        lastDigest = Date()
        app.webType(pm, text: text, enter: true)
        Self.appendLine(PMPaths.inbox, ["kind": "digest", "at": ISO8601DateFormatter().string(from: Date()),
                                        "text": text])
    }

    private func digest(_ events: [Event]) -> String {
        var lines = ["[FleetView 收件箱] 你派出的卡片有 \(events.count) 条变化："]
        for e in events.prefix(12) {
            lines.append("- \(e.name)（\(e.id)，\(e.project)）\(e.what)")
        }
        if events.count > 12 { lines.append("- 另有 \(events.count - 12) 条，见 \(PMPaths.inbox.path)") }
        // Side questions the user asked since the last digest: the main line should know they exist.
        var news: [String] = []
        for k in threads.keys.sorted() {
            guard var th = threads[k] else { continue }
            let answered = th.turns.filter { $0.a != nil }.count
            let seen = th.notified ?? 0
            if answered > seen {
                news.append("\(th.name) +\(answered - seen) 轮 → \(AskThread.mdURL(th).path)")
                th.notified = answered
                threads[k] = th
            }
        }
        if !news.isEmpty {
            lines.append("用户在旁问里问过：" + news.joined(separator: "；"))
            AskThread.saveAll(threads)
        }
        lines.append("按 \(PMPaths.role.path) 的规则处理：用 project-manager show/commits 看清楚再决定，能批就批，需要用户定的就说清楚问什么。")
        return lines.joined(separator: "\n")
    }

    // MARK: Transcripts

    /// Keep a copy of the PM's transcript in `sessions/` each time a turn ends.
    func hookEvent(_ ev: EventWatcher.Event, terminal id: UUID) {
        guard id == terminalId, ev.event == "Stop" || ev.event == "SessionStart",
              let path = ev.transcriptPath else { return }
        DispatchQueue.global(qos: .utility).async { PMCoordinator.mirror(path) }
    }

    /// Append what the copy lacks, or copy it whole when the original is shorter (rewritten).
    nonisolated static func mirror(_ src: String) {
        autoreleasepool {
            let fm = FileManager.default
            try? fm.createDirectory(at: PMPaths.sessions, withIntermediateDirectories: true)
            let dst = PMPaths.sessions.appendingPathComponent((src as NSString).lastPathComponent).path
            guard let srcSize = (try? fm.attributesOfItem(atPath: src))?[.size] as? NSNumber else { return }
            let have = ((try? fm.attributesOfItem(atPath: dst))?[.size] as? NSNumber)?.int64Value ?? -1
            let size = srcSize.int64Value
            if have == size { return }
            if have < 0 || have > size {
                try? fm.removeItem(atPath: dst)
                try? fm.copyItem(atPath: src, toPath: dst)
                return
            }
            guard let r = FileHandle(forReadingAtPath: src), let w = FileHandle(forWritingAtPath: dst) else { return }
            defer { try? r.close(); try? w.close() }
            try? r.seek(toOffset: UInt64(have))
            guard let tail = try? r.readToEnd(), !tail.isEmpty else { return }
            _ = try? w.seekToEnd()
            try? w.write(contentsOf: tail)
        }
    }

    // MARK: Side questions

    struct AskTurn: Codable {
        var id: String
        var q: String
        var a: String?
        var askedAt: Date
        var answeredAt: Date?
        var failed: Bool?
        /// The first question of a fork: the PM's conversation as it was then.
        var forked: Bool?
    }

    /// One project's side-question thread. `fork` is the forked session the follow-ups resume: the
    /// first question forks the PM's conversation, every later one carries on in that fork, so the
    /// thread remembers what it was asked and the PM's own conversation is never touched.
    struct AskThread: Codable {
        var key: String
        var name: String
        var path: String?
        var fork: String?
        var turns: [AskTurn] = []
        var updated: Date
        /// How many answered turns the main line has been told about (in a digest).
        var notified: Int?

        static func loadAll() -> [String: AskThread] {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            guard let d = try? Data(contentsOf: PMPaths.threads),
                  let list = try? dec.decode([AskThread].self, from: d) else { return [:] }
            return Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        }

        static func saveAll(_ all: [String: AskThread]) {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: PMPaths.asks, withIntermediateDirectories: true)
            if let d = try? enc.encode(all.values.sorted { $0.key < $1.key }) {
                try? d.write(to: PMPaths.threads)
            }
        }

        /// `asks/<project name>.md` — named for people and for the PM, not by id. A name used by two
        /// projects gets the second one's id on the end.
        static func mdURL(_ th: AskThread) -> URL {
            let base = th.key == "general" ? "general" : th.name
            var safe = base.map { "/:\\\n\t".contains($0) ? "-" : $0 }.reduce("") { $0 + String($1) }
            if safe.isEmpty || safe.hasPrefix(".") { safe = "project-" + safe }
            if let others = PMCoordinator.sharedNames, others[th.name, default: 0] > 1, th.key != "general" {
                safe += "-" + th.key.prefix(8)
            }
            return PMPaths.asks.appendingPathComponent(safe + ".md")
        }
    }

    /// How many threads use each name, for `mdURL`'s tie-break. Rebuilt whenever threads change.
    nonisolated(unsafe) static var sharedNames: [String: Int]?

    private func saveThreads() {
        Self.sharedNames = threads.values.reduce(into: [:]) { $0[$1.name, default: 0] += 1 }
        AskThread.saveAll(threads)
    }

    /// A thread for a project id, or "general" for questions about no project in particular.
    private func thread(_ key: String) -> AskThread? {
        if var th = threads[key] {
            if let pid = UUID(uuidString: key), let p = app?.project(pid) { th.name = p.name; th.path = p.path }
            return th
        }
        if key == "general" { return AskThread(key: key, name: "通用", path: nil, updated: Date()) }
        guard let pid = UUID(uuidString: key), let p = app?.project(pid) else { return nil }
        return AskThread(key: key, name: p.name, path: p.path, updated: Date())
    }

    enum AskStart { case started, busy, unknown, noSession }

    func ask(key: String, question q: String) -> AskStart {
        guard var th = thread(key) else { return .unknown }
        if let last = th.turns.last, last.a == nil, last.failed != true { return .busy }
        guard let pm = terminalId, let spec = app?.askSpec(pm) else { return .noSession }
        let first = th.fork == nil
        let turn = AskTurn(id: UUID().uuidString, q: q, askedAt: Date(), forked: first ? true : nil)
        th.turns.append(turn)
        th.updated = Date()
        threads[key] = th
        saveThreads()
        Self.appendMarkdown(th, turn: turn)
        // A question starting with "-" would be read as an option by the CLI.
        let body = q.hasPrefix("-") ? " " + q : q
        let prompt = first ? Self.preamble(th) + body : body
        let resume = th.fork ?? spec.sessionId
        let command = spec.command
        let cwd = spec.cwd
        let turnId = turn.id
        DispatchQueue.global(qos: .userInitiated).async {
            let r = PMCoordinator.runAsk(command: command, resume: resume, fork: first, cwd: cwd, prompt: prompt)
            Task { @MainActor [weak self] in self?.finishAsk(key: key, turn: turnId, result: r) }
        }
        return .started
    }

    /// Next question forks the main line afresh — for when the PM has moved on since the fork.
    func refork(key: String) -> Bool {
        guard var th = thread(key) else { return false }
        th.fork = nil
        threads[key] = th
        saveThreads()
        return true
    }

    private func finishAsk(key: String, turn: String, result r: AskResult) {
        guard var th = threads[key], let i = th.turns.firstIndex(where: { $0.id == turn }) else { return }
        th.turns[i].a = r.answer
        th.turns[i].answeredAt = Date()
        if !r.ok { th.turns[i].failed = true }
        if let s = r.session, r.ok { th.fork = s }
        th.updated = Date()
        threads[key] = th
        saveThreads()
        Self.appendMarkdown(th, answer: th.turns[i])
    }

    private static func preamble(_ th: AskThread) -> String {
        let about = th.key == "general" ? "不限定项目" : "项目「\(th.name)」（\(th.path ?? "")）"
        return """
        【旁问 · \(th.name)】这是用户从你的主线分出来的旁问线程，关于\(about)。只读：不要改任何文件，\
        不要给任何卡片发消息、派工或关卡（send/subagent/new/rm/close/key/choose 都不行）；\
        只用 project-manager 的 ls/show/tail/commits/session 之类的只读命令和读文件来查。\
        先给结论，回答要短。这个线程的问答会记在 \(AskThread.mdURL(th).path)，主线以后能读到。

        问题：
        """
    }

    struct AskResult: Sendable { let answer: String; let session: String?; let ok: Bool }

    /// `claude -p` on the fork (or forking the PM's session for a first question), read-only, with the
    /// answer and the session id from its JSON. Blocking; off the main thread.
    nonisolated static func runAsk(command: String, resume: String, fork: Bool, cwd: String,
                                   prompt: String) -> AskResult {
        // Prompt, session and cwd go in as environment variables and are quoted where used, so no
        // text from a request reaches the command line itself; the tool list is ours.
        let tools = PMPaths.askTools.map { "'\($0)'" }.joined(separator: " ")
        let line = #"cd "$FV_CWD" && "# + command +
            #" -p "$FV_Q" --output-format json --permission-mode dontAsk --resume "$FV_SID""# +
            (fork ? " --fork-session" : "") + " --allowedTools " + tools
        let p = Process()
        p.executableURL = URL(fileURLWithPath: FV.userShell)
        p.arguments = ["-lc", line]
        var env = ProcessInfo.processInfo.environment
        env["FV_SID"] = resume
        env["FV_CWD"] = cwd
        env["FV_Q"] = prompt
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return AskResult(answer: "（启动 shell 失败）", session: nil, ok: false) }
        // A question can take a while (it reads); one that hangs must not hold the thread forever.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: killer)
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        killer.cancel()
        if let j = (try? JSONSerialization.jsonObject(with: o)) as? [String: Any] {
            let text = (j["result"] as? String) ?? ""
            let bad = (j["is_error"] as? Bool) == true
            return AskResult(answer: text.isEmpty ? "（没有回答）" : text,
                             session: j["session_id"] as? String, ok: !bad && !text.isEmpty)
        }
        let raw = String(data: o, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let msg = !raw.isEmpty ? raw : e.trimmingCharacters(in: .whitespacesAndNewlines)
        return AskResult(answer: msg.isEmpty ? "（没有回答）" : msg, session: nil, ok: false)
    }

    private static func appendMarkdown(_ th: AskThread, turn: AskTurn) {
        let url = AskThread.mdURL(th)
        var s = ""
        if !FileManager.default.fileExists(atPath: url.path) {
            s += "# 旁问 · \(th.name)\n\n" + (th.path.map { "项目：`\($0)`\n\n" } ?? "")
        }
        if turn.forked == true { s += "---\n\n_\(stamp(turn.askedAt)) 从 PM 主线分叉_\n\n" }
        s += "## 问（\(stamp(turn.askedAt))）\n\n\(turn.q)\n\n"
        append(url, s)
    }

    private static func appendMarkdown(_ th: AskThread, answer t: AskTurn) {
        let mark = t.failed == true ? "答（失败）" : "答"
        append(AskThread.mdURL(th), "## \(mark)（\(stamp(t.answeredAt ?? Date()))）\n\n\(t.a ?? "")\n\n")
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    nonisolated private static func append(_ url: URL, _ s: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let data = Data(s.utf8)
        if let h = FileHandle(forWritingAtPath: url.path) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    nonisolated private static func appendLine(_ url: URL, _ obj: [String: String]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return }
        append(url, s + "\n")
    }

    // MARK: Web

    /// `/manager…` — what the dock and the phone draw the PM's side of things from.
    func webResponse(path: String, query: [String: String]) -> (String, String, Data) {
        func json(_ obj: Any, _ status: String = "200 OK") -> (String, String, Data) {
            (status, "application/json", (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
        }
        switch path {
        case "/manager":
            return json(summary())
        case "/manager/start":
            ensureRunning()
            return json(summary())
        case "/manager/thread":
            guard let k = query["key"], let th = thread(k) else { return json(["error": "unknown"], "404 Not Found") }
            return json(Self.threadJSON(th, full: true))
        case "/manager/ask":
            guard let k = query["key"], let q = query["q"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !q.isEmpty else { return json(["error": "bad request"], "400 Bad Request") }
            switch ask(key: k, question: q) {
            case .started:   return json(["ok": true])
            case .busy:      return json(["error": "busy"], "409 Conflict")
            case .unknown:   return json(["error": "unknown"], "404 Not Found")
            case .noSession: return json(["error": "nosession"], "409 Conflict")
            }
        case "/manager/refork":
            guard let k = query["key"], refork(key: k) else { return json(["error": "unknown"], "404 Not Found") }
            return json(["ok": true])
        default:
            return json(["error": "not found"], "404 Not Found")
        }
    }

    private func summary() -> [String: Any] {
        var out: [String: Any] = ["enabled": Self.enabled, "home": PMPaths.home.path]
        if let id = terminalId, let t = app?.terminals.first(where: { $0.id == id }) {
            out["id"] = id.uuidString
            out["status"] = t.status.rawValue
            out["session"] = app?.askSpec(id) != nil
        }
        out["threads"] = threads.values.sorted { $0.updated > $1.updated }.map { Self.threadJSON($0, full: false) }
        out["workers"] = Array(roster.workers.keys)
        return out
    }

    private static func threadJSON(_ th: AskThread, full: Bool) -> [String: Any] {
        let ms: (Date) -> Double = { ($0.timeIntervalSince1970 * 1000).rounded() }
        var o: [String: Any] = [
            "key": th.key, "name": th.name, "turns": th.turns.count,
            "waiting": th.turns.last.map { $0.a == nil && $0.failed != true } ?? false,
            "forked": th.fork != nil, "updated": ms(th.updated), "file": AskThread.mdURL(th).path,
        ]
        if full {
            o["items"] = th.turns.map { t -> [String: Any] in
                var x: [String: Any] = ["id": t.id, "q": t.q, "askedAt": ms(t.askedAt)]
                if let a = t.a { x["a"] = a }
                if let d = t.answeredAt { x["answeredAt"] = ms(d) }
                if t.failed == true { x["failed"] = true }
                if t.forked == true { x["forked"] = true }
                return x
            }
        }
        return o
    }

    // MARK: Home

    /// Folders, and the role file if there is none — never over one: it is the PM's standing
    /// instructions, and the user edits them.
    static func prepareHome() {
        let fm = FileManager.default
        for d in [PMPaths.home, PMPaths.ledger, PMPaths.sessions, PMPaths.asks] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: PMPaths.role.path) {
            try? PMRole.text.write(to: PMPaths.role, atomically: true, encoding: .utf8)
        }
    }

    struct Roster: Codable {
        var pm: String?
        var workers: [String: Worker] = [:]
        struct Worker: Codable {
            var since: Date
            var name: String?
            var project: String?
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pm = (try? c.decodeIfPresent(String.self, forKey: .pm)) ?? nil
            workers = ((try? c.decodeIfPresent([String: Worker].self, forKey: .workers)) ?? nil) ?? [:]
        }

        static func load() -> Roster {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            guard let d = try? Data(contentsOf: PMPaths.roster) else { return Roster() }
            return (try? dec.decode(Roster.self, from: d)) ?? Roster()
        }

        func save() {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(self) { try? d.write(to: PMPaths.roster, options: .atomic) }
        }
    }
}
