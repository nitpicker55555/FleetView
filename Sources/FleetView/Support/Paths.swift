import Foundation

/// Central paths + small helpers for FleetView's on-disk footprint (~/.fleetview).
enum FV {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var supportDir: URL { home.appendingPathComponent(".fleetview", isDirectory: true) }
    static var stateFile: URL { supportDir.appendingPathComponent("state.json") }
    static var portFile: URL { supportDir.appendingPathComponent("port") }
    static var hookScript: URL { supportDir.appendingPathComponent("hook.sh") }
    static var logFile: URL { supportDir.appendingPathComponent("fleetview.log") }
    static var tmuxConf: URL { supportDir.appendingPathComponent("tmux.conf") }
    static var remoteLog: URL { supportDir.appendingPathComponent("remote.log") }
    static var webPortFile: URL { supportDir.appendingPathComponent("web-port") }   // fleetctl discovers the server here
    /// Per-terminal "which agent session am I on" pointers, written by hook.sh (see HookInstaller).
    static var sessionsDir: URL { supportDir.appendingPathComponent("sessions", isDirectory: true) }
    static func sessionPointer(for termId: UUID) -> URL {
        sessionsDir.appendingPathComponent("\(termId.uuidString).json")
    }
    static var uiDir: URL { supportDir.appendingPathComponent("ui", isDirectory: true) }   // agent-authored dynamic panel
    /// Images sent from the web dashboard. They land here under a generated name and only their
    /// absolute path is typed into the prompt, so the agent reads the file the same way it would
    /// read one you dropped into a desktop terminal.
    static var uploadsDir: URL { supportDir.appendingPathComponent("uploads", isDirectory: true) }
    /// The other direction: files an agent handed to whoever is reading the web dashboard. Each one
    /// is `<uuid>.<ext>` beside a `<uuid>.json` describing it (see `fleetview-send`).
    static var outboxDir: URL { supportDir.appendingPathComponent("outbox", isDirectory: true) }
    static var panelHTML: URL { uiDir.appendingPathComponent("panel.html") }
    static var panelJSON: URL { uiDir.appendingPathComponent("panel.json") }

    /// Structured audit log (one JSON object per line, rotated daily). Distinct from `logFile`,
    /// which stays a free-form debug scratchpad for tuning status heuristics.
    static var logsDir: URL { supportDir.appendingPathComponent("logs", isDirectory: true) }

    // Panel version archive. `panel.html` stays exactly where it was — versions are *copies*, so the
    // skill's contract, the agents writing it and the `/panel` route are all untouched.
    static var panelVersionsDir: URL { uiDir.appendingPathComponent("versions", isDirectory: true) }
    static var panelIndex: URL { panelVersionsDir.appendingPathComponent("index.jsonl") }
    static var panelCurrent: URL { uiDir.appendingPathComponent("current.json") }

    /// Shown in every audit line so an archived log says which build produced it.
    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        default: return "dev"
        }
    }

    /// Just the marketing version ("0.1.0"), which is what a release tag is compared against —
    /// `version` carries the build number too and would not parse.
    static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    static func ensureSupportDir() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }

    /// One append handle, kept open. This is called once per hook event — on the main actor, from
    /// `applyHookEvent` — and PreToolUse/PostToolUse arrive in bursts several times a second, so
    /// opening, seeking and closing the file for each line was four syscalls per event on the thread
    /// drawing the board. O_APPEND also makes the write atomic, which `seekToEnd` then `write` was
    /// not: two callers on different threads could interleave (see RemoteServer's remote.log, which
    /// had 4% of its lines spliced together for exactly that reason).
    private static let logLock = NSLock()
    private static var logHandle: FileHandle?

    /// Append a line to ~/.fleetview/fleetview.log (for tuning status heuristics).
    static func log(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        logLock.lock()
        defer { logLock.unlock() }
        if logHandle == nil {
            ensureSupportDir()
            let fd = open(logFile.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            logHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        try? logHandle?.write(contentsOf: data)
    }

    static var claudeProjectsDir: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }

    /// Claude Code's slug rule for a cwd: replace "/" and "_" with "-".
    static func claudeSlug(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    static func transcriptDir(forCwd cwd: String) -> URL {
        claudeProjectsDir.appendingPathComponent(claudeSlug(for: cwd), isDirectory: true)
    }

    /// The user's login shell (so injected `claude` resolves via their profile PATH).
    static var userShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
