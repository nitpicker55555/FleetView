import Foundation

/// Coarse "how long ago" formatting, à la Claude Code — never an exact clock, just a rough age.
/// Same rules power the desktop card and the web page (which formats a seconds-ago integer).
enum RelativeTime {
    /// e.g. "just now", "42s ago", "5m ago", "3h ago", "2d ago". nil ⇒ show nothing.
    static func short(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        return short(seconds: Int(now.timeIntervalSince(date)))
    }

    /// Format an elapsed-seconds count (negative ⇒ nil, "never interacted").
    static func short(seconds: Int) -> String? {
        guard seconds >= 0 else { return nil }
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let m = seconds / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        return "\(h / 24)d ago"
    }
}
