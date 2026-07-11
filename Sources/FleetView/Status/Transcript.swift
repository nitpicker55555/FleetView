import Foundation

/// Reads a Claude Code transcript JSONL to recover the latest user-typed prompt — used when a
/// terminal resumes an existing session (the UserPromptSubmit hook only fires for *new* prompts).
enum Transcript {
    static func latestUserPrompt(path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // Reverse scan: the last real user prompt is usually near the end.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let ld = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                  (obj["type"] as? String) == "user",
                  (obj["isMeta"] as? Bool) != true,
                  let msg = obj["message"] as? [String: Any],
                  let prompt = promptText(from: msg["content"]), !prompt.isEmpty
            else { continue }
            return prompt
        }
        return nil
    }

    /// Extract typed text from a user message's `content` (string, or an array of blocks —
    /// ignoring tool_result blocks so we don't pick up tool output as a "prompt").
    private static func promptText(from content: Any?) -> String? {
        if let s = content as? String { return clean(s) }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                (block["type"] as? String) == "text" ? (block["text"] as? String) : nil
            }
            return texts.isEmpty ? nil : clean(texts.joined(separator: " "))
        }
        return nil
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
