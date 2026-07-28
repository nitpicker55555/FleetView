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

    # --- FleetView: report each shell command to the dashboard (preexec/precmd) ---
    # preexec reports the command as it starts; precmd reports how it ended. The pair shares a
    # cmd_id so the audit log can join them into one command with a duration and an exit code.
    fleetview_emit() {
      local d="$HOME/.fleetview/events"
      [[ -d "$d" ]] || mkdir -p "$d"
      local base="$d/cmd-$$-$RANDOM$RANDOM"
      print -r -- "$1" > "$base.tmp" 2>/dev/null
      mv -f "$base.tmp" "$base.json" 2>/dev/null
    }

    fleetview_preexec() {
      [[ -z "$FLEETVIEW_TERM_ID" ]] && return
      emulate -L zsh
      local first=${1%% *}
      local cmd="$1"
      cmd="${cmd//\\/\\\\}"
      cmd="${cmd//\"/\\\"}"
      cmd="${cmd//$'\n'/ }"
      cmd="${cmd//$'\t'/ }"
      local cwd="${PWD//\\/\\\\}"
      cwd="${cwd//\"/\\\"}"
      FLEETVIEW_CMD_ID="c$$-$RANDOM$RANDOM"
      FLEETVIEW_CMD_START=$EPOCHREALTIME
      # `claude` keeps its own hooks for *status*, but starting an agent is itself an action worth
      # recording, so the command line is reported for it too.
      [[ "$first" == claude ]] && FLEETVIEW_CMD_QUIET=1 || FLEETVIEW_CMD_QUIET=
      fleetview_emit "{\"event\":\"ShellCommand\",\"term\":\"$FLEETVIEW_TERM_ID\",\"payload\":{\"command\":\"$cmd\",\"cmd_id\":\"$FLEETVIEW_CMD_ID\",\"cwd\":\"$cwd\",\"pid\":$$,\"tty\":\"$TTY\",\"quiet\":\"$FLEETVIEW_CMD_QUIET\"}}"
    }

    fleetview_precmd() {
      # NOT `status`: that name is read-only in zsh, and assigning to it aborts the hook — which
      # silently costs every command its exit code.
      local code=$?
      [[ -z "$FLEETVIEW_TERM_ID" || -z "$FLEETVIEW_CMD_ID" ]] && return
      emulate -L zsh
      local ms=0
      if [[ -n "$FLEETVIEW_CMD_START" ]]; then
        ms=$(( (EPOCHREALTIME - FLEETVIEW_CMD_START) * 1000 ))
        ms=${ms%%.*}
      fi
      fleetview_emit "{\"event\":\"ShellCommandDone\",\"term\":\"$FLEETVIEW_TERM_ID\",\"payload\":{\"cmd_id\":\"$FLEETVIEW_CMD_ID\",\"exit_code\":$code,\"duration_ms\":$ms}}"
      FLEETVIEW_CMD_ID=
      FLEETVIEW_CMD_START=
    }

    zmodload zsh/datetime 2>/dev/null    # EPOCHREALTIME, for command durations
    if autoload -Uz add-zsh-hook 2>/dev/null; then
      add-zsh-hook preexec fleetview_preexec 2>/dev/null
      add-zsh-hook precmd fleetview_precmd 2>/dev/null
    else
      typeset -ga preexec_functions precmd_functions
      preexec_functions+=(fleetview_preexec)
      precmd_functions+=(fleetview_precmd)
    fi
    """# }
}
