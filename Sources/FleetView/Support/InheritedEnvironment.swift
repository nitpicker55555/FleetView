import Foundation

/// What FleetView must not keep from whoever started it.
///
/// Launched from a card's shell — a deploy run by an agent, `open` typed in a FleetView terminal —
/// FleetView inherits that card's environment: its `FLEETVIEW_TERM_ID` and, when the card runs
/// Claude Code, `CLAUDECODE` and every `CLAUDE_CODE_*` of that session (its id, its messaging socket,
/// "child session"). Everything FleetView then starts inherits them in turn, and a `claude -p` it runs
/// for a side question reported its hooks as that card: the card building FleetView showed the PM's
/// side question as its own last prompt (2026-11-11). FleetView is no card and no Claude session, so
/// these go before anything is started. `TMUX`/`TMUX_PANE` stay: a headless FleetView started inside
/// tmux relies on them to restart itself in place after an update.
enum InheritedEnvironment {
    static let dropped = ["FLEETVIEW_TERM_ID", "FLEETVIEW_PORT", "FLEETVIEW_SHELL_DIR", "FLEETVIEW_REAL_ZDOTDIR",
                          "FV_PM_CALLER", "FV_PM_CALLER_HOST", "FV_PM_SERVED", "FV_PM_ORIGIN", "CLAUDECODE"]

    static func scrub() {
        let env = ProcessInfo.processInfo.environment
        var gone: [String] = []
        for k in env.keys where dropped.contains(k) || k.hasPrefix("CLAUDE_CODE_") {
            unsetenv(k)
            gone.append(k)
        }
        if !gone.isEmpty {
            // Said once, so a FleetView that was started from a card can be told apart in the log.
            fputs("FleetView: dropped inherited \(gone.sorted().joined(separator: ", "))\n", stderr)
        }
    }
}
