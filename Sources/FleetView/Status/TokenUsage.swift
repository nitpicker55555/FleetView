import Foundation

/// Parses a Claude Code or Codex CLI transcript into a cumulative "new tokens" time series.
///
/// "New tokens" = fresh input + cache writes + output. Cache *reads* are excluded — they're reused
/// context, not new consumption. This matches how usage/cost is usually reckoned.
///  • Claude: each assistant message carries `message.usage`; we sum per message (de-duped by id).
///  • Codex:  `token_count` events carry a cumulative `total_token_usage`; we read it directly.
enum TokenUsage {
    struct Sample { let t: Date; let cumulativeNew: Int }

    /// Read `path` (plus Claude subagent transcripts) → cumulative new-token curve, sorted by time.
    static func series(path: String) -> [Sample] {
        // Claude writes each subagent's turns to a sibling dir: <transcript w/o .jsonl>/subagents/agent-*.jsonl
        // Those tokens are real usage but live outside the main transcript, so include them.
        var files = [path]
        if path.hasSuffix(".jsonl") {
            let subDir = String(path.dropLast(6)) + "/subagents"
            if let subs = try? FileManager.default.contentsOfDirectory(atPath: subDir) {
                for f in subs where f.hasPrefix("agent-") && f.hasSuffix(".jsonl") { files.append(subDir + "/" + f) }
            }
        }

        var claudeIncrements: [(Date, Int)] = []   // Claude: per-message new tokens (main + subagents)
        var codexCumulative: [(Date, Int)] = []    // Codex: cumulative total_token_usage snapshots
        var seen = Set<String>()                   // de-dup Claude assistant messages by id

        for file in files {
            guard let data = FileManager.default.contents(atPath: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let ld = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else { continue }

                // Codex: token_count → cumulative total_token_usage (payload.info in newer builds).
                if let p = o["payload"] as? [String: Any], (p["type"] as? String) == "token_count" {
                    let container = (p["info"] as? [String: Any]) ?? p
                    if let tu = container["total_token_usage"] as? [String: Any] {
                        let newCum = max(0, int(tu["input_tokens"]) - int(tu["cached_input_tokens"])) + int(tu["output_tokens"])
                        if let t = date(o["timestamp"]) { codexCumulative.append((t, newCum)) }
                    }
                    continue
                }

                // Claude: assistant usage → new = input + cache-writes + output (excl. cache reads).
                if (o["type"] as? String) == "assistant",
                   let m = o["message"] as? [String: Any],
                   let u = m["usage"] as? [String: Any] {
                    let id = (m["id"] as? String) ?? (o["requestId"] as? String) ?? ""
                    if !id.isEmpty { if seen.contains(id) { continue }; seen.insert(id) }
                    let inc = int(u["input_tokens"]) + int(u["cache_creation_input_tokens"]) + int(u["output_tokens"])
                    if let t = date(o["timestamp"]) { claudeIncrements.append((t, inc)) }
                }
            }
        }

        // Codex: cumulative snapshots, clamped non-decreasing (it can interleave sub-thread counters).
        if !codexCumulative.isEmpty {
            var peak = 0
            return codexCumulative.sorted { $0.0 < $1.0 }.map { peak = max(peak, $0.1); return Sample(t: $0.0, cumulativeNew: peak) }
        }
        // Claude: accumulate per-message increments in time order (main + subagents interleaved).
        var cum = 0
        return claudeIncrements.sorted { $0.0 < $1.0 }.map { cum += $0.1; return Sample(t: $0.0, cumulativeNew: cum) }
    }

    /// Compact token count for labels: 512 · 4.2k · 58.8k · 1.2M.
    static func short(_ n: Int) -> String {
        let x = Double(n)
        if n >= 1_000_000 { return String(format: "%.1fM", x / 1_000_000) }
        if n >= 10_000    { return String(format: "%.0fk", x / 1_000) }
        if n >= 1_000     { return String(format: "%.1fk", x / 1_000) }
        return "\(n)"
    }

    // MARK: - Helpers

    private static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return 0
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }
}
