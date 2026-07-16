import Foundation

/// Parses a Claude Code or Codex CLI transcript into a cumulative "new tokens" time series.
///
/// "New tokens" = fresh input + cache writes + output. Cache *reads* are excluded — they're reused
/// context, not new consumption. This matches how usage/cost is usually reckoned.
///  • Claude: each assistant message carries `message.usage`; we sum per message (de-duped by id).
///  • Codex:  `token_count` events carry a cumulative `total_token_usage`; we read it directly.
enum TokenUsage {
    struct Sample { let t: Date; let cumulativeNew: Int }

    /// Read `path` and return its cumulative new-token curve (non-decreasing, sorted by time).
    static func series(path: String) -> [Sample] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var points: [Sample] = []
        var claudeRunning = 0
        var seen = Set<String>()   // de-dup Claude assistant messages by id

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let ld = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else { continue }

            // --- Codex: event_msg / payload.type == token_count → cumulative total_token_usage ---
            // Newer Codex nests it under payload.info; older builds had it directly on payload.
            if let p = o["payload"] as? [String: Any], (p["type"] as? String) == "token_count" {
                let container = (p["info"] as? [String: Any]) ?? p
                if let tu = container["total_token_usage"] as? [String: Any] {
                    let input  = int(tu["input_tokens"])
                    let cached = int(tu["cached_input_tokens"])
                    let output = int(tu["output_tokens"])      // already includes reasoning tokens
                    let newCum = max(0, input - cached) + output
                    if let t = date(o["timestamp"]) { points.append(Sample(t: t, cumulativeNew: newCum)) }
                }
                continue
            }

            // --- Claude: assistant message with message.usage → per-message new, accumulated ---
            if (o["type"] as? String) == "assistant",
               let m = o["message"] as? [String: Any],
               let u = m["usage"] as? [String: Any] {
                let id = (m["id"] as? String) ?? (o["requestId"] as? String) ?? ""
                if !id.isEmpty {
                    if seen.contains(id) { continue }
                    seen.insert(id)
                }
                claudeRunning += int(u["input_tokens"]) + int(u["cache_creation_input_tokens"]) + int(u["output_tokens"])
                if let t = date(o["timestamp"]) { points.append(Sample(t: t, cumulativeNew: claudeRunning)) }
                continue
            }
        }

        // Enforce a non-decreasing cumulative (Codex may interleave counters from sub-threads).
        var peak = 0
        return points.sorted { $0.t < $1.t }.map { s in
            peak = max(peak, s.cumulativeNew)
            return Sample(t: s.t, cumulativeNew: peak)
        }
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
