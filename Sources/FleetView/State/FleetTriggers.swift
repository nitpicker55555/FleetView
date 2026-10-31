import FleetViewAudit
import Foundation

/// What starts a fleet trigger. One shape for every kind, so the file and the HTTP API stay flat:
///
/// - `cron`  — a five-field cron expression, local time (`cron`)
/// - `every` — every `every` seconds
/// - `at`    — once, at `at`
/// - `watch` — when the file at `path` changes, or the direct contents of the folder there
/// - `check` — when the command `check` starts succeeding (exit 0), looked at every `interval` s
/// - `manual`— only when fired: `project-manager trigger fire`, `POST /fleet-triggers/fire`
///
/// Every kind can also be fired by hand, which is how any other program raises one.
struct FleetTriggerWhen: Codable, Sendable, Equatable {
    var kind: String
    var cron: String?
    var every: Double?
    var at: Date?
    var path: String?
    var check: String?
    var interval: Double?

    static let kinds = ["cron", "every", "at", "watch", "check", "manual"]
    var isTimed: Bool { kind == "cron" || kind == "every" || kind == "at" }
}

/// One run: what fired it, how it ended, and the end of what it printed.
struct FleetTriggerRun: Codable, Sendable, Equatable {
    var at: Date
    var reason: String
    /// nil while it runs, and for a run that never started (then `note` says why).
    var exit: Int32?
    var seconds: Double?
    var tail: String?
    var note: String?
}

/// A trigger FleetView itself holds.
///
/// The agents' own schedules (`AgentTrigger`) live inside a CLI process and die with its card. These
/// do not belong to any card: the FleetView process runs them, they survive every card being closed,
/// and what they run is any program — typically `project-manager`, opening or resuming an agent,
/// handing it a prompt and removing the card when it is done. Kept in their own file, not in
/// `state.json`, so a trigger can never cost the board (see the state.json rule in CLAUDE.md).
///
/// Every field added after the first release must be Optional, as in state.json.
struct FleetTrigger: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var when: FleetTriggerWhen
    /// A shell command, run with `zsh -lc` so it sees the login PATH (`project-manager`, `claude`).
    var run: String
    var cwd: String?
    var timeout: Double?
    /// The card whose agent created it (its `FLEETVIEW_TERM_ID`), with that card's name and
    /// conversation at the time — the way back to it when the card has since been removed.
    var source: String?
    var sourceName: String?
    var sourceTranscript: String?
    var createdAt: Date
    var paused: Bool?
    /// The next time-based fire. Persisted, so one that fell while FleetView was not running can be
    /// caught up when it starts again.
    var due: Date?
    var last: FleetTriggerRun?
    var runs: Int?

    static let defaultTimeout: Double = 3600
}

/// A trigger as the UI and the API show it: the stored trigger plus what only the engine knows.
struct FleetTriggerStatus: Sendable, Identifiable, Equatable {
    var trigger: FleetTrigger
    var running: Bool
    var id: String { trigger.id }
}

/// Runs the fleet triggers. Its own queue, its own timer, nothing on the main actor: a check
/// command or a burst of fires must never stall the board.
final class FleetTriggerEngine: @unchecked Sendable {
    static let shared = FleetTriggerEngine()

    /// A run missed while FleetView was not running (quit, updating, crashed) fires once when it
    /// comes back — if it was missed by less than this. A daily job a day late is a different job.
    static let catchUpWindow: TimeInterval = 12 * 3600

    var auditor: Auditor = .disabled
    var onChange: (@Sendable ([FleetTriggerStatus]) -> Void)?

    private let queue = DispatchQueue(label: "ai.eigent.fleetview.fleet-triggers", qos: .utility)
    private var items: [FleetTrigger] = []
    private var procs: [String: Process] = [:]
    private var timedOut: Set<String> = []
    private var lastLook: [String: Date] = [:]
    private var fingerprints: [String: String] = [:]
    private var holds: [String: Bool] = [:]
    private var checking: Set<String> = []
    private var timer: DispatchSourceTimer?

    enum Failure: Error { case invalid(String), notFound }

    // MARK: Lifecycle

    func start() {
        queue.sync {
            guard timer == nil else { return }
            load()
            let now = Date()
            for i in items.indices where items[i].when.isTimed && items[i].paused != true {
                if let due = items[i].due, due <= now {
                    if now.timeIntervalSince(due) <= Self.catchUpWindow {
                        launch(i, reason: "catch-up")
                    }
                    items[i].due = nextDue(items[i], after: now)
                } else if items[i].due == nil, items[i].last == nil || items[i].when.kind != "at" {
                    items[i].due = nextDue(items[i], after: now)
                }
            }
            save()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            publish()
        }
    }

    // MARK: API (any thread)

    func list() -> [FleetTriggerStatus] { queue.sync { snapshot() } }

    func get(_ id: String) -> FleetTrigger? { queue.sync { items.first { $0.id == id } } }

    func add(_ draft: FleetTrigger) throws -> FleetTrigger {
        var t = draft
        try validate(&t)
        return queue.sync {
            t.id = Self.newId(taken: Set(items.map(\.id)))
            t.createdAt = Date()
            t.due = nextDue(t, after: Date())
            items.append(t)
            save(); publish()
            auditor.emit("fleetview.fleet_trigger.created", categories: ["configuration"],
                         message: "trigger \"\(t.name)\" (\(t.when.kind)) → \(t.run.prefix(120))",
                         target: Self.target(t), data: Self.facts(t))
            return t
        }
    }

    /// Removing a trigger also stops a run of it that is still going: removing is how you stop a
    /// runaway, and a run nobody can see in the list any more is one nobody can stop.
    func remove(_ id: String) -> Bool {
        queue.sync {
            guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
            let t = items.remove(at: i)
            if let p = procs[id] { stop(p) }
            lastLook[id] = nil; fingerprints[id] = nil; holds[id] = nil
            save(); publish()
            auditor.emit("fleetview.fleet_trigger.removed", categories: ["configuration"],
                         message: "removed trigger \"\(t.name)\"", target: Self.target(t),
                         data: Self.facts(t))
            return true
        }
    }

    func setPaused(_ id: String, _ paused: Bool) -> FleetTrigger? {
        queue.sync {
            guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
            items[i].paused = paused ? true : nil
            // Resuming starts the schedule from now: a paused trigger has missed nothing on purpose.
            items[i].due = paused ? nil : nextDue(items[i], after: Date())
            holds[id] = nil; fingerprints[id] = nil
            save(); publish()
            auditor.emit("fleetview.fleet_trigger.\(paused ? "paused" : "resumed")",
                         categories: ["configuration"],
                         message: "\(paused ? "paused" : "resumed") trigger \"\(items[i].name)\"",
                         target: Self.target(items[i]))
            return items[i]
        }
    }

    /// Fire by hand. Returns nil when it started, or why it did not.
    func fire(_ id: String) -> String? {
        queue.sync {
            guard let i = items.firstIndex(where: { $0.id == id }) else { return "no such trigger" }
            if procs[id] != nil { return "already running" }
            launch(i, reason: "manual")
            return procs[id] == nil ? (items[i].last?.note ?? "could not start") : nil
        }
    }

    /// The last `lines` lines of its log.
    func log(_ id: String, lines: Int) -> String? {
        queue.sync {
            guard items.contains(where: { $0.id == id }) else { return nil }
            guard let data = try? Data(contentsOf: Self.logURL(id)) else { return "" }
            let text = String(decoding: data.suffix(512 * 1024), as: UTF8.self)
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(lines).joined(separator: "\n")
        }
    }

    // MARK: Validation

    private func validate(_ t: inout FleetTrigger) throws {
        t.name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
        t.run = t.run.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.run.isEmpty { throw Failure.invalid("nothing to run: give a command") }
        if t.name.isEmpty { t.name = String(t.run.prefix(40)) }
        if let c = t.cwd?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
            let p = Self.expand(c)
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &dir), dir.boolValue else {
                throw Failure.invalid("cwd \(c) is not a folder")
            }
            t.cwd = p
        } else { t.cwd = nil }
        if let s = t.timeout, s < 10 || s > 7 * 86400 {
            throw Failure.invalid("timeout must be between 10 s and 7 days")
        }
        var w = t.when
        switch w.kind {
        case "cron":
            guard let c = w.cron, let cron = CronSchedule(c) else {
                throw Failure.invalid("not a cron expression (minute hour day month weekday): \(w.cron ?? "")")
            }
            guard cron.next(after: Date()) != nil else { throw Failure.invalid("\(c) never comes") }
        case "every":
            guard let s = w.every, s >= 10 else { throw Failure.invalid("every needs at least 10 seconds") }
        case "at":
            guard let at = w.at else { throw Failure.invalid("at needs a time") }
            if at < Date().addingTimeInterval(-60) { throw Failure.invalid("\(at) has already passed") }
        case "watch":
            guard let p = w.path?.trimmingCharacters(in: .whitespaces), !p.isEmpty else {
                throw Failure.invalid("watch needs a path")
            }
            w.path = Self.expand(p)
            if let s = w.interval, s < 2 { throw Failure.invalid("watch looks at most every 2 seconds") }
        case "check":
            guard let c = w.check?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else {
                throw Failure.invalid("check needs a command")
            }
            w.check = c
            if let s = w.interval, s < 5 { throw Failure.invalid("check runs at most every 5 seconds") }
        case "manual":
            break
        default:
            throw Failure.invalid("kind must be one of \(Self.kindsList)")
        }
        t.when = w
    }

    private static var kindsList: String { FleetTriggerWhen.kinds.joined(separator: ", ") }

    // MARK: The loop

    private func tick() {
        let now = Date()
        var changed = false
        for i in items.indices where items[i].paused != true {
            let t = items[i]
            switch t.when.kind {
            case "cron", "every", "at":
                guard let due = t.due, due <= now else { continue }
                launch(i, reason: t.when.kind)
                items[i].due = nextDue(items[i], after: now)
                changed = true
            case "watch":
                guard looked(t.id, every: t.when.interval ?? 5, now: now), let path = t.when.path else { continue }
                let fp = Self.fingerprint(path)
                // The first look only learns what is there; a trigger fires on a change it saw.
                if let was = fingerprints[t.id], was != fp { launch(i, reason: "watch") ; changed = true }
                fingerprints[t.id] = fp
            case "check":
                guard !checking.contains(t.id), looked(t.id, every: t.when.interval ?? 60, now: now),
                      let cmd = t.when.check else { continue }
                runCheck(t.id, cmd, cwd: t.cwd)
            default:
                continue
            }
        }
        if changed { save(); publish() }
    }

    private func looked(_ id: String, every s: Double, now: Date) -> Bool {
        if let at = lastLook[id], now.timeIntervalSince(at) < s { return false }
        lastLook[id] = now
        return true
    }

    /// A check fires on the change from "does not hold" to "holds", not on every look while it
    /// holds — "when the build is green, deploy" means once per green, not once a minute.
    private func runCheck(_ id: String, _ cmd: String, cwd: String?) {
        checking.insert(id)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd ?? FV.home.path)
        p.environment = Self.environment(id: id, name: "", reason: "check", source: nil)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            self?.queue.async {
                guard let self else { return }
                self.checking.remove(id)
                guard let i = self.items.firstIndex(where: { $0.id == id }), self.items[i].paused != true else { return }
                let ok = proc.terminationStatus == 0
                if ok, self.holds[id] != true { self.launch(i, reason: "check") ; self.save(); self.publish() }
                self.holds[id] = ok
            }
        }
        do { try p.run() } catch { checking.remove(id); return }
        // A check that hangs must not hold the trigger forever.
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            if p.isRunning { self?.stop(p) }
        }
    }

    private func nextDue(_ t: FleetTrigger, after now: Date) -> Date? {
        switch t.when.kind {
        case "cron": return t.when.cron.flatMap(CronSchedule.init)?.next(after: now)
        case "every": return t.when.every.map { now.addingTimeInterval($0) }
        // Once: due until it has run, and never again after.
        case "at": return t.last == nil ? t.when.at : nil
        default: return nil
        }
    }

    // MARK: Running

    private func launch(_ i: Int, reason: String) {
        let t = items[i]
        if procs[t.id] != nil {
            // One run at a time. A skipped fire is written to the log, not into `last`, which is
            // still describing the run that is going.
            appendLog(t.id, "\n=== \(Self.stamp(Date())) · \(reason) · skipped: the previous run is still going ===\n")
            auditor.emit("fleetview.fleet_trigger.skipped", categories: ["process"],
                         message: "trigger \"\(t.name)\" skipped (\(reason)): still running",
                         target: Self.target(t))
            return
        }
        let url = Self.logURL(t.id)
        Self.trimLog(url)
        appendLog(t.id, "\n=== \(Self.stamp(Date())) · \(reason) ===\n$ \(t.run)\n")
        let start = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard let out = FileHandle(forWritingAtPath: url.path) else { return }
        out.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", t.run]
        p.currentDirectoryURL = URL(fileURLWithPath: t.cwd ?? FV.home.path)
        p.environment = Self.environment(id: t.id, name: t.name, reason: reason, source: t.source)
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        let begun = Date()
        let id = t.id
        p.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.finished(id, proc, begun: begun, reason: reason, from: start, out: out) }
        }
        items[i].last = FleetTriggerRun(at: begun, reason: reason)
        do {
            try p.run()
        } catch {
            try? out.close()
            items[i].last?.note = "could not start: \(error.localizedDescription)"
            appendLog(id, "--- could not start: \(error.localizedDescription) ---\n")
            return
        }
        procs[id] = p
        items[i].runs = (items[i].runs ?? 0) + 1
        auditor.emit("fleetview.fleet_trigger.fired", categories: ["process"],
                     message: "trigger \"\(t.name)\" fired (\(reason))",
                     target: Self.target(t),
                     data: ["fire.reason": .string(reason), "process.pid": .int(Int(p.processIdentifier)),
                            "process.command_line": .string(String(t.run.prefix(2000)))])
        let limit = t.timeout ?? FleetTrigger.defaultTimeout
        queue.asyncAfter(deadline: .now() + limit) { [weak self] in
            guard let self, self.procs[id] === p else { return }
            self.timedOut.insert(id)
            self.stop(p)
        }
        publish()
    }

    private func finished(_ id: String, _ p: Process, begun: Date, reason: String, from offset: Int,
                          out: FileHandle) {
        try? out.close()
        if procs[id] === p { procs[id] = nil }
        let seconds = Date().timeIntervalSince(begun)
        let late = timedOut.remove(id) != nil
        let code = p.terminationStatus
        appendLog(id, "--- \(late ? "timed out, stopped" : "exit \(code)") · \(String(format: "%.1f", seconds)) s ---\n")
        guard let i = items.firstIndex(where: { $0.id == id }) else { publish(); return }
        items[i].last = FleetTriggerRun(at: begun, reason: reason, exit: code, seconds: seconds,
                                        tail: Self.tail(of: Self.logURL(id), from: offset),
                                        note: late ? "timed out after \(Int(items[i].timeout ?? FleetTrigger.defaultTimeout)) s" : nil)
        save(); publish()
        auditor.emit("fleetview.fleet_trigger.finished", categories: ["process"],
                     outcome: code == 0 && !late ? .success : .failure,
                     message: "trigger \"\(items[i].name)\" \(late ? "timed out" : "exited \(code)") after \(Int(seconds)) s",
                     target: Self.target(items[i]),
                     data: ["process.exit_code": .int(Int(code)), "duration_s": .double(seconds),
                            "timed_out": .bool(late)])
    }

    /// TERM to its children and to it, KILL five seconds later to whatever is left. `zsh -lc`
    /// usually execs a lone command, but a pipeline or a `&&` chain keeps the shell as the parent.
    private func stop(_ p: Process) {
        let pid = p.processIdentifier
        Self.signalChildren(of: pid, "-TERM")
        p.terminate()
        queue.asyncAfter(deadline: .now() + 5) {
            guard p.isRunning else { return }
            Self.signalChildren(of: pid, "-KILL")
            kill(pid, SIGKILL)
        }
    }

    private static func signalChildren(of pid: Int32, _ sig: String) {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = [sig, "-P", String(pid)]
        k.standardOutput = FileHandle.nullDevice
        k.standardError = FileHandle.nullDevice
        try? k.run()
        k.waitUntilExit()
    }

    /// The app's own environment, minus what would make a run think it is inside a card, plus who
    /// it is. `FV_PM_CALLER` is what `project-manager` reports as its caller, so the audit log says
    /// which trigger drove which card.
    private static func environment(id: String, name: String, reason: String, source: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["FLEETVIEW_TERM_ID", "TMUX", "TMUX_PANE", "FV_PM_CALLER"] { env[k] = nil }
        env["FV_TRIGGER_ID"] = id
        env["FV_TRIGGER_NAME"] = name
        env["FV_TRIGGER_REASON"] = reason
        env["FV_TRIGGER_SOURCE"] = source ?? ""
        env["FV_PM_CALLER"] = "trigger:" + id
        return env
    }

    // MARK: State

    private func snapshot() -> [FleetTriggerStatus] {
        items.map { FleetTriggerStatus(trigger: $0, running: procs[$0.id] != nil) }
    }

    private func publish() {
        let s = snapshot()
        onChange?(s)
    }

    private func load() {
        guard let data = try? Data(contentsOf: FV.fleetTriggersFile) else { return }
        do {
            items = try Self.decoder.decode([FleetTrigger].self, from: data)
        } catch {
            // Not overwritten with an empty list on the next save: the broken file is kept aside,
            // which is the difference between a lost trigger and a lost afternoon of them.
            let aside = FV.fleetTriggersFile.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: FV.fleetTriggersFile, to: aside)
            FV.log("fleet triggers: could not read \(FV.fleetTriggersFile.path) (\(error)); kept a copy at \(aside.lastPathComponent)")
        }
    }

    private func save() {
        guard let data = try? Self.encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: FV.supportDir, withIntermediateDirectories: true)
        try? data.write(to: FV.fleetTriggersFile, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Helpers

    static func logURL(_ id: String) -> URL { FV.fleetTriggerLogs.appendingPathComponent("\(id).log") }

    private func appendLog(_ id: String, _ text: String) {
        let url = Self.logURL(id)
        try? FileManager.default.createDirectory(at: FV.fleetTriggerLogs, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: url.path) else { return }
        h.seekToEndOfFile()
        h.write(Data(text.utf8))
        try? h.close()
    }

    /// Past 1 MB, keep the last 256 KB: a trigger that runs every minute for a month would
    /// otherwise grow its log without bound.
    private static func trimLog(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > 1_000_000, let data = try? Data(contentsOf: url) else { return }
        try? data.suffix(256 * 1024).write(to: url)
    }

    private static func tail(of url: URL, from offset: Int) -> String? {
        guard let data = try? Data(contentsOf: url), data.count > offset else { return nil }
        let out = String(decoding: data.dropFirst(offset).suffix(2000), as: UTF8.self)
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : out
    }

    /// What a watch compares: a file's size and modification time; for a folder, the same for each
    /// thing directly inside it. Not recursive — every two seconds over a whole tree is not cheap.
    static func fingerprint(_ path: String) -> String {
        let fm = FileManager.default
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &dir) else { return "missing" }
        func stamp(_ p: String) -> String {
            let a = try? fm.attributesOfItem(atPath: p)
            let m = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(a?[.size] as? Int ?? 0)@\(m)"
        }
        guard dir.boolValue else { return stamp(path) }
        let names = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
        return names.map { $0 + ":" + stamp((path as NSString).appendingPathComponent($0)) }.joined(separator: "|")
    }

    static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

    private static func newId(taken: Set<String>) -> String {
        while true {
            let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            if !taken.contains(id) { return id }
        }
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    static func target(_ t: FleetTrigger) -> AuditTarget {
        AuditTarget(kind: "fleet_trigger", id: t.id, name: t.name)
    }

    static func facts(_ t: FleetTrigger) -> [String: AuditValue] {
        AuditValue.compact([
            "trigger.kind": .string(t.when.kind),
            "trigger.cron": t.when.cron.map { .string($0) },
            "trigger.every_s": t.when.every.map { .double($0) },
            "trigger.path": t.when.path.map { .string($0) },
            "trigger.check": t.when.check.map { .string($0) },
            "process.command_line": .string(String(t.run.prefix(2000))),
            "trigger.source.card": t.source.map { .string($0) },
            "trigger.source.name": t.sourceName.map { .string($0) },
        ])
    }
}
