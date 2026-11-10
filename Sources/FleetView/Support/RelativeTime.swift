import Foundation

/// Coarse "how long ago" formatting, à la Claude Code — never an exact clock, just a rough age.
/// Same rules power the desktop card and the web page (which formats a seconds-ago integer).
enum RelativeTime {
    /// The one instant every clock on the board counts its ticks from (see `Ticker`).
    ///
    /// The board's clocks used to be anchored each on its own date — a run's start, a card's last
    /// activity, the moment a view appeared — so with five cards running ~15 one-second clocks fired
    /// at ~15 different instants a second, each an update pass of its own (measured 2026-11-10: 359
    /// clock updates in 33 s while scrolling). From a shared epoch they fire on the same instant, in
    /// one pass. What a clock shows is still computed from its own date; only when it redraws is shared.
    static let tickEpoch = Date(timeIntervalSinceReferenceDate: 0)

    /// e.g. "just now", "42s ago", "5m ago", "3h ago", "2d ago". nil ⇒ show nothing.
    static func short(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        return short(seconds: Int(now.timeIntervalSince(date)))
    }

    /// A stopwatch for a run in progress: "0:42", "12:07", "1:03:19". Exact, and seconds-resolution,
    /// unlike `short` — this one is watched while it ticks, not glanced at.
    static func clock(seconds: Int) -> String {
        let s = max(0, seconds)
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func clock(since date: Date, now: Date = Date()) -> String {
        clock(seconds: Int(now.timeIntervalSince(date)))
    }

    /// How long ago, as compactly as it can be said: "刚刚", "25m", "5h", "4d". What a card shows
    /// when nothing is running — the unit letter is enough once you have seen it.
    static func compact(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return L(.justNow) }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        return "\(h / 24)d"
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
