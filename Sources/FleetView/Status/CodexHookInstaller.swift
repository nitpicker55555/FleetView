import Foundation

/// Installs FleetView's status hooks into ~/.codex/config.toml so Codex CLI sessions launched in
/// FleetView terminals report live status + prompts — reusing the same hook.sh + events pipeline as
/// the Claude Code hooks. Codex's lifecycle hooks mirror Claude's (SessionStart / UserPromptSubmit /
/// PreToolUse / PermissionRequest / PostToolUse / Stop) and deliver JSON on stdin, so hook.sh works
/// unchanged. The shared script no-ops unless FLEETVIEW_TERM_ID is set, so it never reports for codex
/// runs outside FleetView. Our block is fenced by sentinel comments and removed cleanly on uninstall.
///
/// Deliberately not installed into sub-pool's `codex-home/config.toml`, the file `sp-codex` reads.
/// Codex keys a hook's trust on the config file's path as the CLI sees it,
/// `$CODEX_HOME/config.toml:<event>:0:0`, and `sp-codex` points CODEX_HOME at a fresh
/// `sp-codex-XXXXXXXX` temp dir every session: a trust recorded against the file's real path is
/// ignored, and one recorded against the session's path is dead by the next session (both tried
/// with codex-cli 0.153.4 — only the exact session path fired). The hooks would sit there
/// untrusted in every session and never run. `sp-codex` cards get their
/// status from the rollout instead, exactly as Codex cards did before their hooks were trusted
/// (`CodexSession`); what that cannot see is an approval prompt.
enum CodexHookInstaller {
    // Codex lifecycle events we care about. PermissionRequest is Codex's approval signal (Claude uses
    // "Notification"); PreToolUse/PostToolUse clear "needs you" once the user approves.
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse",
                         "PostToolUse", "PermissionRequest", "Stop"]

    static var codexDir: URL { FV.home.appendingPathComponent(".codex", isDirectory: true) }
    static var configURL: URL { codexDir.appendingPathComponent("config.toml") }
    static var backupURL: URL { FV.supportDir.appendingPathComponent("codex-config.backup.toml") }

    private static let fenceStart = "# >>> FleetView status hooks (auto-generated — safe to delete) >>>"
    private static let fenceEnd   = "# <<< FleetView status hooks <<<"

    static func isInstalled() -> Bool {
        guard let s = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        return s.contains(fenceStart)
    }

    @discardableResult
    static func install() -> Bool {
        // Only adapt for users who already use Codex — never create ~/.codex ourselves.
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return false }
        HookInstaller.writeHookScript()               // shared event-writer script (idempotent)

        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        // Back up the user's original config once, before our first modification.
        if !existing.isEmpty, !FileManager.default.fileExists(atPath: backupURL.path) {
            FV.ensureSupportDir()
            try? existing.write(to: backupURL, atomically: true, encoding: .utf8)
        }

        let base = stripFence(existing).trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = (base.isEmpty ? hookBlock() : base + "\n\n" + hookBlock()) + "\n"
        guard combined != existing else { return true }   // already current — don't churn the file

        do { try combined.write(to: configURL, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }

    @discardableResult
    static func uninstall() -> Bool {
        guard let existing = try? String(contentsOf: configURL, encoding: .utf8),
              existing.contains(fenceStart) else { return false }
        let stripped = stripFence(existing).trimmingCharacters(in: .whitespacesAndNewlines)
        let out = stripped.isEmpty ? "" : stripped + "\n"
        do { try out.write(to: configURL, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }

    // MARK: - Helpers

    private static func hookBlock() -> String {
        let path = FV.hookScript.path
        var lines = [fenceStart]
        for e in events {
            lines.append("[[hooks.\(e)]]")
            lines.append("[[hooks.\(e).hooks]]")
            lines.append("type = \"command\"")
            lines.append("command = \"\(path) \(e)\"")
            lines.append("")
        }
        lines.append(fenceEnd)
        return lines.joined(separator: "\n")
    }

    /// Remove our fenced block (inclusive) line-by-line, leaving the user's own content intact —
    /// including whatever Codex itself has written inside the fence.
    ///
    /// Codex records which hooks you trusted in this same file, as `[hooks.state."<key>"]` tables
    /// holding a `trusted_hash`, and its TOML editor files a new table after its siblings: after
    /// our `[[hooks.*]]` tables, so inside the fence. That alone made the file differ from what
    /// `install()` writes, so the next launch rewrote it and stripping the fence whole threw the
    /// trust away: all six hooks came back "untrusted" (Codex's own hooks/list said so after the
    /// 2026-10-01 relaunch), Codex skips those without a word, and FleetView heard nothing from a
    /// new Codex session until someone reviewed the hooks in Codex again. So inside the fence only
    /// our own `[[hooks.*]]` tables go; any other table, and its lines, stays.
    private static func stripFence(_ s: String) -> String {
        guard s.contains(fenceStart) else { return s }
        var out: [String] = []
        var inside = false
        var foreign = false
        for line in s.components(separatedBy: "\n") {
            if line.contains(fenceStart) { inside = true; foreign = false; continue }
            if line.contains(fenceEnd) { inside = false; continue }
            if !inside { out.append(line); continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { foreign = !t.hasPrefix("[[hooks.") }
            if foreign { out.append(line) }
        }
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
