import Foundation

/// Getting a typed prompt to actually *submit* in an agent's TUI, and knowing whether it did.
///
/// `send-keys -l <text>` followed straight away by `send-keys Enter` reads, to Codex, as a paste
/// with a Return inside it: the text lands as one burst, and Codex's paste-burst guard turns a
/// Return that arrives inside the burst window into a newline — that is what stops a pasted
/// multi-line block from submitting at its first line. Measured on codex-cli 0.153.4: with the two
/// tmux calls back to back the Enter was eaten every time and the prompt sat in the composer
/// looking sent; with a 10 ms gap it submitted. Claude Code 2.1 drops it too, less often, on long
/// text — a 1,287-character prompt stayed put, and so did a second Enter two seconds later.
///
/// A delay alone does not fix it. The window is measured when the TUI *reads* the keys, and a busy
/// TUI (mid-turn, redrawing a stream) reads a backlog in one go, collapsing whatever gap was left.
/// So the Enter is followed by a look at the pane: if the text is still in the composer, press
/// Enter again. That look is also what lets `/type?wait=1` say "submitted" rather than "sent".
///
/// Foundation only, and tmux is reached through a closure, so the whole sequence can be driven
/// against real agents outside the app — which is how it was verified.
enum Submit {
    /// What happened to one `/type`.
    enum Outcome: String, Sendable {
        case typed        // enter=0: text only, by request
        case sent         // Enter pressed, not checked — short text, not an agent pane, or the
                          // text never showed up in the composer to be checked
        case submitted    // checked: the text reached the composer, then left it
        case stuck        // checked: still in the composer after every retry
        case superseded   // another write to this terminal arrived first; stopped checking
    }

    /// Run a tmux command: arguments, and whether to capture stdout.
    typealias Tmux = ([String], Bool) -> String

    /// Checks after the first Enter, each of which presses Enter again if the text is still there.
    static let retries = 4

    /// Type `text` into `session` and, if `enter`, submit it and confirm.
    ///
    /// Blocking — it sleeps between steps — so it runs on the terminal's own write queue, where the
    /// only thing it delays is the next write to the same terminal, which has to wait for it anyway.
    /// `superseded` reports that a later write to this terminal is queued: from then on the caller
    /// has moved on, and an Enter pressed on its behalf could land on whatever it is doing now.
    static func run(text: String, enter: Bool, session: String,
                    superseded: () -> Bool, tmux: Tmux) -> Outcome {
        // A pane scrolled back is in tmux copy-mode, whose key table binds neither the characters
        // nor Enter: everything typed is dropped without a trace. Codex reports no mouse, so the
        // web's scroll buttons and a wheel over the desktop window both put it there — reading back
        // before replying was enough to lose the reply. auto-recover.sh lost six 继续 this way.
        if tmux(["display-message", "-p", "-t", session, "#{pane_in_mode}"], true)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            _ = tmux(["send-keys", "-X", "-t", session, "cancel"], false)
        }
        if !text.isEmpty { _ = tmux(["send-keys", "-t", session, "-l", "--", text], false) }
        guard enter else { return .typed }
        // A menu answer ("1"), a y/n: too short to trip a paste guard, and — the real reason — a
        // digit is on screen in every numbered menu, so "is it still showing" cannot be asked of it.
        guard let probe = probe(for: text) else {
            _ = tmux(["send-keys", "-t", session, "Enter"], false)
            return .sent
        }
        Thread.sleep(forTimeInterval: gap(for: text))
        // A shell running a command is not a composer: a second Enter there answers whatever that
        // command is waiting on. Only agents get the retries.
        let agent = isAgent(tmux(["display-message", "-p", "-t", session, "#{pane_current_command}"],
                                 true))
        // See the text arrive before claiming anything about it leaving. "Gone from the composer"
        // is also what text that never landed looks like — a TUI still drawing its banner drops
        // keystrokes — and reporting that as submitted is the lie this whole check exists to stop.
        var arrived = false
        if agent {
            for _ in 0..<3 {
                if composerHolds(tmux(["capture-pane", "-p", "-t", session], true), probe: probe) {
                    arrived = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        // The first Enter is the one the caller asked for, so it goes regardless. Only the retries
        // are ours to withhold.
        _ = tmux(["send-keys", "-t", session, "Enter"], false)
        guard agent, arrived else { return .sent }
        for attempt in 0...retries {
            Thread.sleep(forTimeInterval: attempt == 0 ? 0.5 : 0.7)
            if superseded() { return .superseded }
            let pane = tmux(["capture-pane", "-p", "-t", session], true)
            if !composerHolds(pane, probe: probe) { return .submitted }
            if attempt == retries { break }
            _ = tmux(["send-keys", "-t", session, "Enter"], false)
        }
        return .stuck
    }

    /// The tail of what was typed, as the composer would show it with its wrapping taken out.
    ///
    /// The tail, not the head: a long prompt scrolls inside Claude's composer, which keeps the end
    /// in view — the first line of a 1,300-character prompt was already off the top when checked.
    /// nil when there is too little text to recognise.
    static func probe(for text: String) -> String? {
        let s = squeeze(text)
        guard s.count >= 3 else { return nil }
        return String(s.suffix(12))
    }

    /// Time to leave between the text and its Enter. Idle Codex needed ~10 ms; the rest is margin
    /// for a TUI that is busy, and for long text, which takes longer to ingest.
    static func gap(for text: String) -> TimeInterval {
        0.12 + min(0.4, Double(text.count) / 4000)
    }

    /// Whether the composer at the bottom of `pane` still holds the text `probe` came from.
    ///
    /// The composer is the last line opening with a prompt marker (Codex `›`, Claude `❯`) and
    /// whatever follows it. Earlier marker lines are history — both agents keep a submitted prompt
    /// on screen under its marker, so "any marker line contains the text" is true long after it
    /// ran; that is the mistake an earlier check made. Once the text is in, the last marker line is
    /// an empty composer or its placeholder. A menu shows markers too (`› 1. Yes`), which is fine:
    /// it is not the text we typed.
    ///
    /// A composer that collapsed the text into a placeholder is also still holding it.
    static func composerHolds(_ pane: String, probe: String) -> Bool {
        let lines = pane.components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: isMarkerLine) else { return false }
        let region = lines[start...].joined(separator: "\n")
        if region.contains("[Pasted text") || region.contains("[Pasted Content") { return true }
        return squeeze(region).contains(probe)
    }

    static func isMarkerLine(_ line: String) -> Bool {
        let t = line.drop(while: { $0 == " " || $0 == "│" })
        guard let c = t.first else { return false }
        if c == "›" || c == "❯" { return true }
        return c == ">" && t.dropFirst().first == " "
    }

    /// The pane's foreground process is an agent CLI. Claude installed natively runs as a binary
    /// named after its version (`2.1.280`), so a version-shaped name counts too.
    static func isAgent(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if c.hasPrefix("claude") || c.hasPrefix("codex") || c == "node" { return true }
        return c.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil
    }

    /// Text with every space, line break and box edge taken out — what survives a TUI re-wrapping
    /// it at a different width with its own indentation.
    static func squeeze(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "│"
        }.map(Character.init))
    }
}

/// A per-terminal count of writes, so a check in flight can tell that a newer write has arrived.
///
/// Bumped on the main actor as each request comes in — before it queues — and read from the write
/// queue, hence the lock.
final class WriteLedger: @unchecked Sendable {
    private var counts: [String: UInt64] = [:]
    private let lock = NSLock()

    @discardableResult
    func bump(_ session: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        counts[session, default: 0] += 1
        return counts[session]!
    }

    func current(_ session: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return counts[session] ?? 0
    }
}
