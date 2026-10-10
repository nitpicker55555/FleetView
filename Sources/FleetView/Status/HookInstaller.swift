import Foundation

/// Installs (and cleanly removes) FleetView's Claude Code status hooks in ~/.claude/settings.json,
/// and in sub-pool's `claude-home/settings.json` when `sp-claude` is set up — that is the only
/// settings file `sp-claude` reads (see AgentHome).
/// The hook script no-ops unless FLEETVIEW_TERM_ID is set, so it never affects normal `claude` use.
enum HookInstaller {
    // PreToolUse lets us clear "needs you" the instant the user approves a permission prompt
    // (Claude fires it as work resumes; without it the card stayed stuck on "needs you").
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "Notification"]

    /// The Claude homes whose settings get our hooks. Unlike Codex's, a Claude hook needs no trust
    /// recorded against the file's path, so sub-pool's per-session temp dir does not get in the way.
    static var homes: [AgentHome] { [.claude] + (AgentHome.subPoolClaude.exists ? [.subPoolClaude] : []) }
    static func settingsURL(_ home: AgentHome) -> URL { home.dir.appendingPathComponent("settings.json") }
    static func backupURL(_ home: AgentHome) -> URL {
        FV.supportDir.appendingPathComponent(home.viaSubPool ? "sp-claude-settings.backup.json"
                                                             : "settings.backup.json")
    }

    static func writeHookScript() {
        FV.ensureSupportDir()
        let script = #"""
        #!/bin/bash
        # FleetView status hook. No-ops unless launched by FleetView (FLEETVIEW_TERM_ID set),
        # so it never affects your normal `claude` usage.
        [ -z "$FLEETVIEW_TERM_ID" ] && exit 0
        dir="$HOME/.fleetview/events"
        mkdir -p "$dir"
        payload=$(cat)
        [ -z "$payload" ] && payload=null
        base="$dir/$$-$RANDOM$RANDOM"
        printf '{"event":"%s","term":"%s","payload":%s}' "$1" "$FLEETVIEW_TERM_ID" "$payload" > "$base.tmp" 2>/dev/null
        mv -f "$base.tmp" "$base.json" 2>/dev/null
        # Durable terminal → session binding. Events are consumed once and then deleted, so a single
        # missed one (another FleetView reading the queue, a restart mid-flight) would leave the
        # terminal pointing at a stale transcript forever — e.g. after `claude --resume` switches
        # sessions. This pointer is rewritten by the terminal's own hook on every event, so it is
        # always current and can't be lost to the queue.
        sdir="$HOME/.fleetview/sessions"
        mkdir -p "$sdir"
        # Unique temp name: hooks for one terminal can run concurrently, and sharing a temp path
        # lets one invocation rename the file another is still writing.
        stmp="$sdir/.$FLEETVIEW_TERM_ID.$$-$RANDOM"
        printf '%s' "$payload" > "$stmp" 2>/dev/null
        mv -f "$stmp" "$sdir/$FLEETVIEW_TERM_ID.json" 2>/dev/null || rm -f "$stmp" 2>/dev/null
        exit 0
        """#
        try? script.write(to: FV.hookScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: FV.hookScript.path)
    }

    static func isInstalled() -> Bool {
        homes.contains { home in
            guard let obj = readSettings(home), let hooks = obj["hooks"] as? [String: Any] else { return false }
            return events.contains { groupIndexOfOurs(in: hooks[$0] as? [[String: Any]] ?? []) != nil }
        }
    }

    @discardableResult
    static func install() -> Bool {
        writeHookScript()
        return homes.map { install($0) }.allSatisfy { $0 }
    }

    @discardableResult
    static func uninstall() -> Bool {
        homes.map { uninstall($0) }.allSatisfy { $0 }
    }

    private static func install(_ home: AgentHome) -> Bool {
        let settingsURL = settingsURL(home), backupURL = backupURL(home)
        var obj = readSettings(home) ?? [:]
        // Back up the original once, before our first modification.
        if !FileManager.default.fileExists(atPath: backupURL.path),
           let data = try? Data(contentsOf: settingsURL) {
            FV.ensureSupportDir()
            try? data.write(to: backupURL)
        }
        var hooks = (obj["hooks"] as? [String: Any]) ?? [:]
        for e in events {
            var arr = (hooks[e] as? [[String: Any]]) ?? []
            if groupIndexOfOurs(in: arr) == nil {
                arr.append(["hooks": [["type": "command", "command": command(for: e)]]])
            }
            hooks[e] = arr
        }
        obj["hooks"] = hooks
        return writeSettings(obj, home)
    }

    private static func uninstall(_ home: AgentHome) -> Bool {
        guard var obj = readSettings(home), var hooks = obj["hooks"] as? [String: Any] else { return false }
        for e in events {
            guard var arr = hooks[e] as? [[String: Any]] else { continue }
            arr.removeAll { group in groupIsOurs(group) }
            if arr.isEmpty { hooks.removeValue(forKey: e) } else { hooks[e] = arr }
        }
        if hooks.isEmpty { obj.removeValue(forKey: "hooks") } else { obj["hooks"] = hooks }
        return writeSettings(obj, home)
    }

    // MARK: - Helpers

    private static func command(for event: String) -> String { "\(FV.hookScript.path) \(event)" }

    private static func groupIsOurs(_ group: [String: Any]) -> Bool {
        guard let hs = group["hooks"] as? [[String: Any]] else { return false }
        return hs.contains { ($0["command"] as? String)?.contains(FV.hookScript.path) ?? false }
    }

    private static func groupIndexOfOurs(in arr: [[String: Any]]) -> Int? {
        arr.firstIndex(where: groupIsOurs)
    }

    private static func readSettings(_ home: AgentHome) -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL(home)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Written in place, not replaced, so a settings file that is a symlink stays one — sub-pool's
    /// home is wired to `~/.claude` by links (its `projects` and `skills` are), and an atomic
    /// rename would silently cut this one loose.
    private static func writeSettings(_ obj: [String: Any], _ home: AgentHome) -> Bool {
        guard let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys]) else { return false }
        do { try out.write(to: settingsURL(home)); return true } catch { return false }
    }
}
