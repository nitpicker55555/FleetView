import Foundation

/// Installs (and cleanly removes) FleetView's Claude Code status hooks in ~/.claude/settings.json.
/// The hook script no-ops unless FLEETVIEW_TERM_ID is set, so it never affects normal `claude` use.
enum HookInstaller {
    // PreToolUse lets us clear "needs you" the instant the user approves a permission prompt
    // (Claude fires it as work resumes; without it the card stayed stuck on "needs you").
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "Notification"]
    static var settingsURL: URL { FV.home.appendingPathComponent(".claude/settings.json") }
    static var backupURL: URL { FV.supportDir.appendingPathComponent("settings.backup.json") }

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
        exit 0
        """#
        try? script.write(to: FV.hookScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: FV.hookScript.path)
    }

    static func isInstalled() -> Bool {
        guard let obj = readSettings(), let hooks = obj["hooks"] as? [String: Any] else { return false }
        for e in events where groupIndexOfOurs(in: hooks[e] as? [[String: Any]] ?? []) != nil { return true }
        return false
    }

    @discardableResult
    static func install() -> Bool {
        writeHookScript()
        var obj = readSettings() ?? [:]
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
        return writeSettings(obj)
    }

    @discardableResult
    static func uninstall() -> Bool {
        guard var obj = readSettings(), var hooks = obj["hooks"] as? [String: Any] else { return false }
        for e in events {
            guard var arr = hooks[e] as? [[String: Any]] else { continue }
            arr.removeAll { group in groupIsOurs(group) }
            if arr.isEmpty { hooks.removeValue(forKey: e) } else { hooks[e] = arr }
        }
        if hooks.isEmpty { obj.removeValue(forKey: "hooks") } else { obj["hooks"] = hooks }
        return writeSettings(obj)
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

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func writeSettings(_ obj: [String: Any]) -> Bool {
        guard let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys]) else { return false }
        do { try out.write(to: settingsURL); return true } catch { return false }
    }
}
