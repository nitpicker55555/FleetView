import Foundation

/// Central paths + small helpers for FleetView's on-disk footprint (~/.fleetview).
enum FV {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var supportDir: URL { home.appendingPathComponent(".fleetview", isDirectory: true) }
    static var stateFile: URL { supportDir.appendingPathComponent("state.json") }
    static var portFile: URL { supportDir.appendingPathComponent("port") }
    static var hookScript: URL { supportDir.appendingPathComponent("hook.sh") }
    static var logFile: URL { supportDir.appendingPathComponent("fleetview.log") }

    static func ensureSupportDir() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
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
