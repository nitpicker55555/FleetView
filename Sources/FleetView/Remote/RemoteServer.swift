import Foundation

/// Everything the TerminalWindowController needs to run a terminal *inside* a FleetView tmux
/// session (so a second client — the web view via ttyd — can attach to the very same session).
struct TmuxSpec {
    let tmuxPath: String
    let socket: String
    let confPath: String
    let session: String
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
        guard let ttydPath, let tmuxPath, let ip = Tooling.lanIP() else { return nil }
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
            "-W",                                   // writable: let the browser type, not just watch
            "-t", "titleFixed=\(name) · FleetView",
            "-t", "disableLeaveAlert=true",
            tmuxPath, "-L", RemoteServer.socket, "attach", "-t", session,
        ]
        // ttyd inherits the GUI app's minimal PATH; make sure it can still find tmux's deps.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env
        if let log = try? FileHandle(forWritingTo: prepareLog()) {
            log.seekToEndOfFile()
            proc.standardOutput = log
            proc.standardError = log
        }
        do { try proc.run() } catch { return nil }
        instances[id] = (port, proc)
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

    /// Send a named key (Escape, Enter, arrows, C-c…) — the web quick-keys for driving an agent.
    /// Whitelisted so a query param can't inject an arbitrary tmux command.
    func sendKey(_ id: UUID, _ key: String) {
        let allowed: Set<String> = ["Escape", "Enter", "Tab", "Space", "BSpace",
                                    "Up", "Down", "Left", "Right", "PageUp", "PageDown",
                                    "C-c", "C-d", "C-z", "C-l", "C-u", "C-a", "C-e"]
        guard allowed.contains(key), tmuxPath != nil else { return }
        runTmux(["send-keys", "-t", RemoteServer.sessionName(for: id), key])
    }

    /// Stop a terminal's web server and destroy its tmux session (called on Remove Terminal).
    func stop(_ id: UUID) {
        if let inst = instances.removeValue(forKey: id), inst.proc.isRunning {
            inst.proc.terminate()
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
        set -g mouse off              # don't hijack scroll/selection from the app (Claude TUI, etc.)
        set -g window-size latest     # multi-client size follows the most-recently-active client
        setw -g aggressive-resize on
        set -g history-limit 50000
        set -g focus-events on
        set -g destroy-unattached off # keep the session alive when the desktop window closes
        set -g default-terminal "tmux-256color"
        set -ga terminal-overrides ",*:Tc"   # truecolor passthrough
        """
        try? conf.write(to: FV.tmuxConf, atomically: true, encoding: .utf8)
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
}
