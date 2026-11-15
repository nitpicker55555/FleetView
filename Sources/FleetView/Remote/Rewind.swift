import Foundation

/// Taking a conversation back to before one of its prompts, from the web — the agent's own Esc Esc,
/// driven through its TUI, so the agent itself does the rewinding and keeps its history the way it
/// always does (Claude: a new branch in the same file; Codex: a `<tid>_<rid>` segment, see CodexTree).
///
/// Both pick the prompt from a list on screen, and nothing in that list is addressable: no ids, no
/// numbers, only rows a key moves through. So every step is read back before the next is taken, and
/// a prompt counts only when its WHOLE text is on screen and equal to the one asked for — `nth`
/// counts exact repeats, the way the page counted them. A list that stops moving before the prompt
/// turns up is backed out of. Measured on Claude Code 2.1.319 and codex-cli 0.167.0 (2026-11-15):
///
/// - Claude: Esc Esc on an empty composer opens "Rewind" with `❯ (current)` selected; Up walks back a
///   prompt at a time. A row is the prompt's first line, ending in "…" when there is more of it (cut
///   at the width, or more lines) — so a row is only a candidate. Enter on it asks "Confirm you want
///   to restore to the point before you sent this message:" over a quote of the whole prompt and its
///   age ("(40s ago)"); Escape there goes back to the list on the same row. Then `1. Restore
///   conversation`, `2. Summarize from here`… — plus code-restoring choices when files changed,
///   which are never taken: this rewinds the conversation only. The prompt comes back in the composer.
/// - Codex: the first Esc says "esc again to edit previous message", the second opens "Browsing
///   transcript" with the last prompt drawn in reverse video — all of it, every wrapped and every
///   further line. Left walks back. Enter rewinds at once ("Conversation reverted to this point. File
///   changes are unchanged.") and refills the composer.
///
/// Either way the composer is emptied afterwards: the page that asked has the prompt's full text
/// (the composer may only hold a paste placeholder), and its own Send is what goes next. An Escape
/// while the agent is working interrupts the turn, so the caller only ever asks of an idle agent.
///
/// Foundation only, tmux through a closure, like Submit — so it is run against real agents outside
/// the app.
enum Rewind {
    enum Agent: Sendable { case claude, codex }

    enum Outcome: Equatable, Sendable {
        case done
        /// Why not, as a key the page has words for.
        case failed(String)
    }

    /// Rows walked at most before giving up: a long session lists hundreds of prompts.
    static let maxSteps = 600

    /// Rewind `session` to before the `nth` prompt (1 = the latest) whose text is `prompt`.
    /// Blocking; runs on the terminal's write queue.
    static func run(agent: Agent, prompt: String, nth: Int, session: String,
                    tmux: Submit.Tmux) -> Outcome {
        func key(_ k: String) { _ = tmux(["send-keys", "-t", session, k], false) }
        func screen() -> String { tmux(["capture-pane", "-p", "-t", session], true) }
        func styled() -> String { tmux(["capture-pane", "-p", "-e", "-t", session], true) }
        func waitFor(_ ok: (String) -> Bool, _ seconds: Double) -> String? {
            let end = Date().addingTimeInterval(seconds)
            repeat {
                let s = screen()
                if ok(s) { return s }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < end
            return nil
        }
        /// Out of whatever was opened.
        func backOut(_ why: String, escapes: Int) -> Outcome {
            for _ in 0..<escapes { key("Escape"); Thread.sleep(forTimeInterval: 0.25) }
            return .failed(why)
        }

        if tmux(["display-message", "-p", "-t", session, "#{pane_in_mode}"], true)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            _ = tmux(["send-keys", "-X", "-t", session, "cancel"], false)
        }
        // Esc Esc opens the list only from an empty composer. Text typed there is somebody's draft,
        // and clearing it to get in could not be undone faithfully — typing a multi-line draft back
        // presses Enter at its first line break — so it is left alone and the page says why.
        guard let draft = Submit.composerDraft(styled()) else { return .failed("noComposer") }
        guard draft.isEmpty else { return .failed("draft") }

        let want = max(1, nth)
        switch agent {
        case .claude:
            key("Escape"); Thread.sleep(forTimeInterval: 0.15); key("Escape")
            // A suggestion drawn in the composer can take the first Escape for itself; one more then
            // completes the pair. On an idle agent a stray Escape does nothing.
            if waitFor({ claudeList($0) != nil }, 1.5) == nil {
                key("Escape")
                guard waitFor({ claudeList($0) != nil }, 1.5) != nil else { return backOut("noMenu", escapes: 0) }
            }
            var seen = 0, last = ""
            var chosen: (quote: String, options: [String], selected: Int)?
            for step in 0...maxSteps {
                guard let list = claudeList(screen()) else { return backOut("noMenu", escapes: 1) }
                if list.selected != "(current)", same(list.selected, prompt) {
                    key("Enter")
                    guard let c = waitFor({ claudeConfirm($0) != nil }, 2.5).flatMap(claudeConfirm) else {
                        return backOut("unconfirmed", escapes: 2)
                    }
                    if same(c.quote, prompt) {
                        seen += 1
                        if seen == want { chosen = c; break }
                    }
                    key("Escape")       // back to the list, on the same row
                    guard waitFor({ claudeList($0) != nil }, 2) != nil else { return backOut("noMenu", escapes: 1) }
                }
                // The whole list, not the row: two identical prompts in a row look the same under the
                // cursor, but the cursor's line and the "↓ n more" under it have moved.
                if step > 0, list.block == last {
                    Thread.sleep(forTimeInterval: 0.3)
                    if claudeList(screen())?.block == last { return backOut("notFound", escapes: 1) }
                }
                last = list.block
                key("Up"); Thread.sleep(forTimeInterval: 0.12)
            }
            guard let confirm = chosen else { return backOut("notFound", escapes: 1) }
            guard let target = confirm.options.firstIndex(of: "Restore conversation") else {
                return backOut("noRestore", escapes: 2)
            }
            let moves = target - confirm.selected
            for _ in 0..<abs(moves) { key(moves > 0 ? "Down" : "Up"); Thread.sleep(forTimeInterval: 0.1) }
            guard let now = claudeConfirm(screen()), now.options.indices.contains(now.selected),
                  now.options[now.selected] == "Restore conversation" else {
                return backOut("noRestore", escapes: 2)
            }
            key("Enter")
            guard waitFor({ claudeConfirm($0) == nil && claudeList($0) == nil }, 4) != nil else {
                return .failed("unconfirmed")
            }
        case .codex:
            key("Escape")
            guard waitFor({ $0.contains("esc again to edit previous message") }, 1.5) != nil else {
                return backOut("noMenu", escapes: 0)
            }
            key("Escape")
            guard waitFor({ $0.contains("Browsing transcript") }, 2) != nil else {
                return backOut("noMenu", escapes: 1)
            }
            var seen = 0, last = "", found = false
            for step in 0...maxSteps {
                let s = styled()
                guard let selected = codexSelected(s) else { return backOut("noMenu", escapes: 1) }
                if same(selected, prompt) {
                    seen += 1
                    if seen == want { found = true; break }
                }
                if step > 0, s == last {
                    Thread.sleep(forTimeInterval: 0.3)
                    if styled() == last { return backOut("notFound", escapes: 1) }
                }
                last = s
                key("Left"); Thread.sleep(forTimeInterval: 0.15)
            }
            guard found else { return backOut("notFound", escapes: 1) }
            key("Enter")
            guard waitFor({ !$0.contains("Browsing transcript") }, 4) != nil else { return .failed("unconfirmed") }
        }
        // The prompt comes back into the composer; take it out again (see the type's comment).
        Thread.sleep(forTimeInterval: 0.4)
        if let back = Submit.composerDraft(styled()), !back.isEmpty {
            Submit.clearComposer(lines: back.components(separatedBy: "\n").count, session: session, tmux: tmux)
        }
        return .done
    }

    /// Whether what the screen shows is `prompt`: the same text once wrapping and spacing are taken
    /// out, or — when it ends in "…" — the start of it, which makes it only a candidate (see `run`).
    static func same(_ shown: String, _ prompt: String) -> Bool {
        var s = Submit.squeeze(shown)
        let p = Submit.squeeze(prompt)
        guard !s.isEmpty, !p.isEmpty else { return false }
        guard s.hasSuffix("…") else { return s == p }
        s.removeLast()
        return p.count > s.count && p.hasPrefix(s)
    }

    /// Claude's prompt list: the row under the cursor, and the list as drawn.
    static func claudeList(_ screen: String) -> (selected: String, block: String)? {
        let lines = screen.components(separatedBy: "\n")
        guard let top = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Rewind" }),
              lines[top...].contains(where: { $0.contains("Restore the code and/or conversation") }),
              let end = lines[top...].firstIndex(where: { $0.contains("Enter to continue") })
        else { return nil }
        let block = lines[top...end]
        guard let row = block.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") })
        else { return nil }
        let text = row.trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
        return (text, block.joined(separator: "\n"))
    }

    /// Claude's confirmation: the prompt it quotes (every line of it, its age taken off), its
    /// numbered choices, and which one is selected.
    static func claudeConfirm(_ screen: String) -> (quote: String, options: [String], selected: Int)? {
        let lines = screen.components(separatedBy: "\n")
        guard let head = lines.lastIndex(where: { $0.contains("Confirm you want to restore") }) else { return nil }
        var quote: [String] = [], options: [String] = [], selected = -1
        for line in lines[(head + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("│") {
                quote.append(t.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            let marked = t.hasPrefix("❯")
            let body = marked ? t.dropFirst().trimmingCharacters(in: .whitespaces) : t
            guard let dot = body.firstIndex(of: "."), let n = Int(body[..<dot]), n == options.count + 1
            else { continue }
            if marked { selected = options.count }
            options.append(body[body.index(after: dot)...].trimmingCharacters(in: .whitespaces))
        }
        // The quote's last line is its age: "(16s ago)".
        if let age = quote.last, age.hasPrefix("("), age.hasSuffix(")") { quote.removeLast() }
        guard !quote.isEmpty, !options.isEmpty, selected >= 0 else { return nil }
        return (quote.joined(separator: "\n"), options, selected)
    }

    /// The prompt Codex's transcript browser has selected — every line of it, which is every line
    /// drawn in reverse video from its `›` marker on. From a capture WITH escapes.
    static func codexSelected(_ styled: String) -> String? {
        let lines = styled.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            Submit.stripEscapes($0).drop(while: { $0 == " " }).hasPrefix("› ") && firstTextIsReverse($0, after: "›")
        }) else { return nil }
        var out = [String(Submit.stripEscapes(lines[start]).drop(while: { $0 == " " }).dropFirst(2))]
        for line in lines[(start + 1)...] {
            let plain = Submit.stripEscapes(line).trimmingCharacters(in: .whitespaces)
            // A blank line inside the prompt captures as "" — no character, so no reverse either, and
            // no different from the blank line after it. Blanks are passed over (`same` ignores
            // spacing anyway); the first line with text that is not reversed is where it ends.
            if plain.isEmpty { continue }
            guard firstTextIsReverse(line, after: nil) else { break }
            out.append(plain)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the first character drawn on `line` — after `marker`, when there is one — has SGR 7.
    static func firstTextIsReverse(_ line: String, after marker: Character?) -> Bool {
        let u = Array(line.unicodeScalars)
        var reverse = false, past = marker == nil, i = 0
        while i < u.count {
            let c = u[i]
            if c == "\u{1B}", i + 1 < u.count, u[i + 1] == "[" {
                var j = i + 2, params = ""
                while j < u.count, !(0x40...0x7E).contains(u[j].value) { params.unicodeScalars.append(u[j]); j += 1 }
                if j < u.count, u[j] == "m" {
                    if params.isEmpty { reverse = false }
                    for p in params.split(separator: ";") {
                        if p == "7" { reverse = true } else if p == "0" || p == "27" { reverse = false }
                    }
                }
                i = j + 1
                continue
            }
            if !past {
                if let marker, Character(c) == marker { past = true }
            } else if c != " " && c != "\u{A0}" {
                return reverse
            }
            i += 1
        }
        return false
    }
}
