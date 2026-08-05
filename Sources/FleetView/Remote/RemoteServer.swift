import FleetViewAudit
import Foundation

/// Everything the TerminalWindowController needs to run a terminal *inside* a FleetView tmux
/// session (so a second client — the web view via ttyd — can attach to the very same session).
struct TmuxSpec {
    let tmuxPath: String
    let socket: String
    let confPath: String
    let session: String
}

/// What `ask` needs to run a forked, context-aware side query for a terminal's agent.
struct AskSpec: Sendable {
    let sessionId: String   // the agent session (transcript filename without .jsonl)
    let cwd: String
    let agent: String       // "claude" / "codex" / ""
}

/// Serves FleetView terminals to other devices over the LAN.
///
/// Each terminal runs inside a private tmux session (see `TmuxSpec`). The local SwiftTerm window is
/// one attached client; `ttyd` (bundled xterm.js) is another. Both mirror the same session, so what
/// you see and type on the web is exactly what's in the desktop window. tmux + ttyd are external
/// tools — if either is missing, terminals fall back to a plain shell and remote access is disabled.
@MainActor
final class RemoteServer {
    /// Dedicated tmux socket so FleetView's server never collides with the user's own tmux.
    static let socket = "fleetview"
    private static let basePort = 7681

    let tmuxPath: String?
    let ttydPath: String?

    private var instances: [UUID: (port: Int, proc: Process)] = [:]
    private var nextPort = RemoteServer.basePort

    struct Endpoint { let url: String; let port: Int; let session: String }

    init() {
        tmuxPath = Tooling.find("tmux")
        ttydPath = Tooling.find("ttyd")
    }

    var available: Bool { tmuxPath != nil && ttydPath != nil }

    var unavailableReason: String {
        switch (tmuxPath == nil, ttydPath == nil) {
        case (true, true):  return "brew install tmux ttyd"
        case (true, false): return "brew install tmux"
        case (false, true): return "brew install ttyd"
        default:            return ""
        }
    }

    /// Stable tmux session name for a terminal (hex, no dashes — tmux-safe, collision-free).
    static func sessionName(for id: UUID) -> String {
        "fv_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// What to hand a TerminalWindowController so it launches under tmux (nil ⇒ plain shell).
    func tmuxSpec(for id: UUID) -> TmuxSpec? {
        guard let tmuxPath else { return nil }
        return TmuxSpec(tmuxPath: tmuxPath, socket: RemoteServer.socket,
                        confPath: FV.tmuxConf.path, session: RemoteServer.sessionName(for: id))
    }

    private var sessionCache: Set<String> = []
    private var sessionCacheAt = Date.distantPast

    /// Names of all live FleetView tmux sessions, cached ~2s so `/state` polling stays cheap (one
    /// `list-sessions` instead of one `has-session` per terminal). Lets the web mark a "closed"
    /// terminal openable when its session is still alive (reattach from another device).
    func liveSessions() -> Set<String> {
        let now = Date()
        if now.timeIntervalSince(sessionCacheAt) < 2.0 { return sessionCache }
        sessionCacheAt = now
        guard let tmuxPath else { sessionCache = []; return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxPath)
        p.arguments = ["-L", RemoteServer.socket, "list-sessions", "-F", "#{session_name}"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { sessionCache = []; return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let names = String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
        sessionCache = Set(names)
        return sessionCache
    }

    /// True if the tmux session already exists (⇒ we're re-attaching, so don't re-type `claude`).
    func sessionExists(_ id: UUID) -> Bool {
        guard let tmuxPath else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxPath)
        p.arguments = ["-L", RemoteServer.socket, "has-session", "-t", RemoteServer.sessionName(for: id)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Start (or reuse) a ttyd serving this terminal's session, and return its LAN URL.
    func endpoint(for id: UUID, name: String) -> Endpoint? {
        guard let ttydPath, let tmuxPath, let ip = Tooling.preferredIP() else { return nil }
        let session = RemoteServer.sessionName(for: id)

        if let inst = instances[id], inst.proc.isRunning {
            return Endpoint(url: "http://\(ip):\(inst.port)/", port: inst.port, session: session)
        }

        var port = nextPort
        while !Tooling.isPortFree(port) { port += 1 }
        nextPort = port + 1

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ttydPath)
        proc.arguments = [
            "-p", "\(port)",
            "-6",                                   // dual-stack, see below
            "-W",                                   // writable: let the browser type, not just watch
            "-t", "titleFixed=\(name) · FleetView",
            "-t", "disableLeaveAlert=true",
            tmuxPath, "-L", RemoteServer.socket, "-u", "attach", "-t", session,   // -u: force UTF-8 to this client (CJK)
        ]
        // `-6` because without it ttyd listens on IPv4 only, while FleetView's own dashboard socket
        // is dual-stack. A client that reaches the dashboard over IPv6 therefore gets a working Chat
        // tab (same origin) and a terminal iframe pointing at a port nothing answers on — the page
        // rebuilds that URL from `location.hostname`, so it inherits the address family it arrived
        // on. It costs one extra listening socket and makes the two servers agree.
        //
        // ttyd inherits the GUI app's minimal PATH; make sure it can still find tmux's deps.
        // A GUI app launched from Finder has no LANG, so tmux would treat this client as non-UTF-8
        // and replace Chinese with "?"; set a UTF-8 locale so the web renders CJK correctly.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["LANG"] = "en_US.UTF-8"
        env["LC_CTYPE"] = "en_US.UTF-8"
        proc.environment = env
        if let log = appendHandle() {
            proc.standardOutput = log
            proc.standardError = log
        }
        do { try proc.run() } catch { return nil }
        instances[id] = (port, proc)
        // Do not answer until it is actually listening. `run()` returns at spawn, ttyd binds ~20ms
        // later, and the browser opens the iframe the instant this response lands — losing that race
        // is a blank terminal that never retries on its own. Typically a ~20ms wait; the cap is
        // there so a ttyd that fails to start cannot hold the main actor.
        if !Tooling.waitForPort(port, timeout: 2.0) {
            FV.log("ttyd on :\(port) did not start listening within 2s — serving the URL anyway")
        }
        // A terminal becoming reachable from other devices is a security-relevant fact, and one no
        // state diff would show — the model is unchanged, a listener simply appeared.
        AppAudit.shared.auditor.emit("fleetview.ttyd.started",
                                     categories: ["network"],
                                     message: "terminal \"\(name)\" is now served on :\(port)",
                                     target: AuditTarget(kind: "terminal", id: id.uuidString, name: name),
                                     data: ["port": .int(port),
                                            "pid": .int(Int(proc.processIdentifier)),
                                            "writable": .bool(true),
                                            "tmux_session": .string(session)])
        return Endpoint(url: "http://\(ip):\(port)/", port: port, session: session)
    }

    /// Inject literal text into a session (used by the web input bar — robust CJK/IME input that
    /// bypasses xterm.js). `enter` also sends a Return so a typed prompt is submitted.
    func sendText(_ id: UUID, text: String, enter: Bool) {
        guard tmuxPath != nil else { return }
        let session = RemoteServer.sessionName(for: id)
        if !text.isEmpty { runTmux(["send-keys", "-t", session, "-l", "--", text]) }
        if enter { runTmux(["send-keys", "-t", session, "Enter"]) }
    }

    /// Scroll a terminal for the web view's on-screen buttons (phones can't wheel-scroll).
    /// A full-screen TUI (Claude/Codex) runs on the alternate screen and grabs the mouse itself, so
    /// tmux copy-mode can't touch it — instead we feed it real SGR wheel events and IT scrolls its own
    /// view. A plain shell (main screen, no mouse) uses tmux copy-mode scrollback.
    func scroll(_ id: UUID, up: Bool) {
        guard tmuxPath != nil else { return }
        let session = RemoteServer.sessionName(for: id)
        if displayFlag(session, "#{mouse_any_flag}") == "1" {
            // A full-screen mouse app (Claude/Codex enabled SGR mouse): feed it discrete wheel events
            // just like a real trackpad. ESC [ < 64 ; 40 ; 15 M  (64 = wheel up, 65 = wheel down).
            let button: [UInt8] = up ? [0x36, 0x34] : [0x36, 0x35]
            let seq = ([0x1b, 0x5b, 0x3c] + button + [0x3b, 0x34, 0x30, 0x3b, 0x31, 0x35, 0x4d])
                .map { String(format: "%02x", $0) }
            for _ in 0..<4 { runTmux(["send-keys", "-t", session, "-H"] + seq) }
        } else {
            runTmux(["copy-mode", "-e", "-t", session])
            runTmux(["send-keys", "-X", "-t", session, up ? "halfpage-up" : "halfpage-down"])
        }
    }

    /// Read one tmux format string for a session (e.g. "#{mouse_any_flag}").
    private func displayFlag(_ session: String, _ fmt: String) -> String {
        guard let tmuxPath else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxPath)
        p.arguments = ["-L", RemoteServer.socket, "display-message", "-p", "-t", session, fmt]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Send a named key (Escape, Enter, arrows, C-c…) — the web quick-keys for driving an agent.
    /// Whitelisted so a query param can't inject an arbitrary tmux command.
    func sendKey(_ id: UUID, _ key: String) {
        let allowed: Set<String> = ["Escape", "Enter", "Tab", "Space", "BSpace",
                                    "Up", "Down", "Left", "Right", "PageUp", "PageDown",
                                    "C-c", "C-d", "C-z", "C-l", "C-u", "C-a", "C-e"]
        guard allowed.contains(key), tmuxPath != nil else { return }
        runTmux(["send-keys", "-t", RemoteServer.sessionName(for: id), key])
    }

    /// Ask the terminal's agent a one-off question using the SAME conversation context but WITHOUT
    /// touching the live session — Claude `--fork-session` (print mode) forks into a throwaway session,
    /// so the running terminal keeps going undisturbed. Returns the agent's answer text. Blocking;
    /// callers must run it off the main thread. `nonisolated` so it can run on a background queue.
    nonisolated static func ask(_ spec: AskSpec, question: String) -> String {
        // Run through a LOGIN shell so the agent inherits the user's real environment (PATH + auth) —
        // a GUI-launched app's env lacks it, and claude/codex would report "Not logged in". The prompt,
        // session id and cwd are passed as env vars (referenced quoted) so arbitrary text can't inject.
        let tool = spec.agent == "codex"
            ? #"codex exec resume "$FV_SID" "$FV_Q""#
            : #"claude -p --resume "$FV_SID" --fork-session "$FV_Q""#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: FV.userShell)
        p.arguments = ["-lc", #"cd "$FV_CWD" && "# + tool]
        var env = ProcessInfo.processInfo.environment
        env["FV_SID"] = spec.sessionId
        env["FV_CWD"] = spec.cwd
        env["FV_Q"] = question
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return "(failed to launch shell)" }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        p.waitUntilExit()
        if !o.isEmpty { return o }
        return e.isEmpty ? "(no answer)" : e
    }

    /// Capture the terminal's visible screen + `lines` of scrollback as plain text (for `fleetctl`
    /// to show the conversation and scan for error-terminated sessions).
    func capture(_ id: UUID, lines: Int) -> String? {
        guard let tmuxPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxPath)
        p.arguments = ["-L", RemoteServer.socket, "capture-pane", "-p", "-t",
                       RemoteServer.sessionName(for: id), "-S", "-\(max(0, lines))"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stop a terminal's web server and destroy its tmux session (called on Remove Terminal).
    func stop(_ id: UUID) {
        if let inst = instances.removeValue(forKey: id) {
            if inst.proc.isRunning { inst.proc.terminate() }
            AppAudit.shared.auditor.emit("fleetview.ttyd.stopped",
                                         categories: ["network"],
                                         message: "stopped serving a terminal on :\(inst.port)",
                                         target: AuditTarget(kind: "terminal", id: id.uuidString),
                                         data: ["port": .int(inst.port)])
        }
        runTmux(["kill-session", "-t", RemoteServer.sessionName(for: id)])
    }

    /// On quit, stop the web servers (free the ports) but LEAVE the tmux sessions running, so an
    /// agent keeps working while FleetView is closed and reattaches when you reopen the terminal.
    /// Sessions are only destroyed by an explicit Remove Terminal (`stop`). Orphan ttyd from a hard
    /// kill self-resolve — the next launch just picks fresh ports.
    func stopAll() {
        for (_, inst) in instances where inst.proc.isRunning { inst.proc.terminate() }
        instances.removeAll()
    }

    // MARK: - Setup

    /// Write FleetView's tmux config (idempotent; call once at launch). A dedicated socket + config
    /// keeps tmux invisible: no prefix key stealing, no status bar, instant Escape (Claude interrupt),
    /// and multi-client resize that follows whichever client is active.
    static func installConfig() {
        FV.ensureSupportDir()
        let conf = """
        # FleetView tmux — a transparent multiplexer so the desktop window (SwiftTerm) and the
        # web view (ttyd) share ONE session. Loaded only on FleetView's private `-L fleetview` socket.
        set -g escape-time 0          # forward Escape instantly (Claude's interrupt key)
        set -g status off             # no green status bar — looks like a plain terminal
        set -g prefix None            # disable the Ctrl-b prefix entirely: zero key interception
        set -g prefix2 None
        # Scrolling: mouse ON so the wheel scrolls tmux's scrollback (copy-mode) on the desktop and
        # in a desktop browser. With it OFF, the outer terminal (on tmux's alt screen) turns the wheel
        # into Up/Down arrow keys — the "scroll acts like arrow keys" bug. Phones can't wheel-scroll,
        # so the web view has explicit scroll buttons (see /scroll). Drag-select copies to the clipboard.
        set -g mouse on
        set -g set-clipboard on
        bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "pbcopy"
        bind -T copy-mode    MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "pbcopy"
        # Canonical smart wheel: forward a REAL wheel to full-screen mouse apps (Claude/Codex scroll
        # themselves), send arrows to alt-screen pagers (less), copy-mode for a plain shell. This makes
        # the desktop window and a desktop browser scroll correctly with no synthetic events.
        bind -n WheelUpPane   if -F "#{mouse_any_flag}" "send -M" { if -F "#{alternate_on}" "send -N3 Up" "copy-mode -e" }
        bind -n WheelDownPane if -F "#{mouse_any_flag}" "send -M" { if -F "#{alternate_on}" "send -N3 Down" "send -M" }
        set -g window-size latest     # multi-client size follows the most-recently-active client
        setw -g aggressive-resize on
        set -g history-limit 50000
        set -g focus-events on
        set -g destroy-unattached off # keep the session alive when the desktop window closes
        set -g default-terminal "tmux-256color"
        set -ga terminal-overrides ",*:Tc"   # truecolor passthrough
        """
        try? conf.write(to: FV.tmuxConf, atomically: true, encoding: .utf8)
        // Reload into an already-running server so open sessions pick up the change immediately
        // (a running server keeps its old options; only new servers read the file fresh).
        if let tmux = Tooling.find("tmux") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tmux)
            p.arguments = ["-L", socket, "source-file", FV.tmuxConf.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
    }

    // MARK: - Private

    private func runTmux(_ args: [String]) {
        guard let tmuxPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxPath)
        p.arguments = ["-L", RemoteServer.socket] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        p.waitUntilExit()
    }

    private func prepareLog() -> URL {
        let url = FV.remoteLog
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    /// A write handle every ttyd can share. O_APPEND matters: each instance used to get its own
    /// handle seeked to the end, and "seek then write" is two steps — concurrent instances wrote
    /// over each other, leaving lines spliced together mid-word. 4% of this log was torn that way,
    /// and it is the only record of which client actually reached a terminal.
    private func appendHandle() -> FileHandle? {
        let fd = open(prepareLog().path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }
}
