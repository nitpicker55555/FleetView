import Foundation

/// zsh integration: FleetView-launched terminals get a private ZDOTDIR whose wrapper files source
/// the user's real startup files (with the *real* ZDOTDIR restored, so history/paths resolve
/// normally), then install a `preexec` hook reporting each shell command to the dashboard.
/// Scoped to FleetView's own terminals — the user's normal shells and ~/.zshrc are untouched.
enum ShellIntegration {
    static var dir: URL { FV.supportDir.appendingPathComponent("shell", isDirectory: true) }

    static var supportsCurrentShell: Bool { (FV.userShell as NSString).lastPathComponent == "zsh" }

    static func install() {
        guard supportsCurrentShell else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        write(".zshenv", zshenv)
        write(".zprofile", zprofile)
        write(".zshrc", zshrc)
        // Remove a stray history file from an earlier version that used our dir as HISTFILE.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(".zsh_history"))
    }

    /// Extra env for a spawned zsh: point ZDOTDIR at us, remember the real one.
    static func env() -> [String] {
        guard supportsCurrentShell else { return [] }
        let real = ProcessInfo.processInfo.environment["ZDOTDIR"] ?? FV.home.path
        return ["ZDOTDIR=\(dir.path)",
                "FLEETVIEW_SHELL_DIR=\(dir.path)",
                "FLEETVIEW_REAL_ZDOTDIR=\(real)"]
    }

    private static func write(_ name: String, _ content: String) {
        try? content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // Each wrapper restores the real ZDOTDIR while sourcing the user's file, then re-points to
    // our dir so zsh finds the next wrapper. (.zshrc leaves it restored for .zlogin + session.)
    private static let restoreReal = #"if [[ "$FLEETVIEW_REAL_ZDOTDIR" == "$HOME" ]]; then unset ZDOTDIR; else export ZDOTDIR="$FLEETVIEW_REAL_ZDOTDIR"; fi"#

    private static var zshenv: String { #"""
    # FleetView zsh integration — source the user's real startup files, keep our ZDOTDIR to find wrappers.
    : ${FLEETVIEW_REAL_ZDOTDIR:=$HOME}
    \#(restoreReal)
    [[ -f "$FLEETVIEW_REAL_ZDOTDIR/.zshenv" ]] && source "$FLEETVIEW_REAL_ZDOTDIR/.zshenv"
    [[ -n "$FLEETVIEW_SHELL_DIR" ]] && export ZDOTDIR="$FLEETVIEW_SHELL_DIR"
    """# }

    private static var zprofile: String { #"""
    \#(restoreReal)
    [[ -f "$FLEETVIEW_REAL_ZDOTDIR/.zprofile" ]] && source "$FLEETVIEW_REAL_ZDOTDIR/.zprofile"
    [[ -n "$FLEETVIEW_SHELL_DIR" ]] && export ZDOTDIR="$FLEETVIEW_SHELL_DIR"
    """# }

    private static var zshrc: String { #"""
    \#(restoreReal)
    [[ -f "$FLEETVIEW_REAL_ZDOTDIR/.zshrc" ]] && source "$FLEETVIEW_REAL_ZDOTDIR/.zshrc"
    # ZDOTDIR now stays at the user's real value for .zlogin and the rest of the session.

    # keep shell history in the user's real location, never FleetView's dir
    [[ "$HISTFILE" == "$FLEETVIEW_SHELL_DIR/"* ]] && HISTFILE="$FLEETVIEW_REAL_ZDOTDIR/.zsh_history"

    # --- FleetView: report each non-claude shell command to the dashboard (preexec) ---
    fleetview_preexec() {
      [[ -z "$FLEETVIEW_TERM_ID" ]] && return
      local first=${1%% *}
      [[ "$first" == claude ]] && return          # claude is tracked via Claude Code hooks
      emulate -L zsh
      local cmd="$1"
      cmd="${cmd//\\/\\\\}"
      cmd="${cmd//\"/\\\"}"
      cmd="${cmd//$'\n'/ }"
      cmd="${cmd//$'\t'/ }"
      local d="$HOME/.fleetview/events"
      [[ -d "$d" ]] || mkdir -p "$d"
      local base="$d/cmd-$$-$RANDOM$RANDOM"
      print -r -- "{\"event\":\"ShellCommand\",\"term\":\"$FLEETVIEW_TERM_ID\",\"payload\":{\"command\":\"$cmd\"}}" > "$base.tmp" 2>/dev/null
      mv -f "$base.tmp" "$base.json" 2>/dev/null
    }
    autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook preexec fleetview_preexec 2>/dev/null || { typeset -ga preexec_functions; preexec_functions+=(fleetview_preexec); }
    """# }
}
