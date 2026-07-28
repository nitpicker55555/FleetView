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

    static func ensureSupportDir() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }

    /// Append a line to ~/.fleetview/fleetview.log (for tuning status heuristics).
    static func log(_ message: String) {
        ensureSupportDir()
        guard let data = (message + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFile.path),
           let fh = try? FileHandle(forWritingTo: logFile) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: logFile)
        }
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
