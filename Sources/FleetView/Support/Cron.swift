import Foundation

/// A five-field cron expression — minute, hour, day of month, month, day of week — in local time.
///
/// The ordinary dialect and nothing more: `*`, numbers, `a-b` ranges, `a,b` lists and `/n` steps,
/// with 0 or 7 for Sunday. When both day fields are restricted, a day matching either one counts,
/// as in Vixie cron — "the 1st, and every Monday" — which is the rule people expect even when they
/// could not state it.
struct CronSchedule: Equatable, Sendable {
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    private let anyDay: Bool
    private let anyWeekday: Bool

    init?(_ text: String) {
        let f = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard f.count == 5,
              let mi = Self.field(f[0], 0...59), let h = Self.field(f[1], 0...23),
              let d = Self.field(f[2], 1...31), let mo = Self.field(f[3], 1...12),
              var w = Self.field(f[4], 0...7) else { return nil }
        if w.contains(7) { w.remove(7); w.insert(0) }
        minutes = mi; hours = h; days = d; months = mo; weekdays = w
        anyDay = f[2].hasPrefix("*"); anyWeekday = f[4].hasPrefix("*")
    }

    private static func field(_ s: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var out = Set<Int>()
        for part in s.split(separator: ",") {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { return nil }
            var step = 1
            if pieces.count == 2 {
                guard let n = Int(pieces[1]), n > 0 else { return nil }
                step = n
            }
            let base = pieces[0]
            var lo = range.lowerBound, hi = range.upperBound
            if base != "*" {
                let ends = base.split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(ends.count), let a = Int(ends[0]),
                      let b = ends.count == 2 ? Int(ends[1]) : a else { return nil }
                // "5/15" means "from 5, every 15" — a single number with a step runs to the end.
                lo = a; hi = ends.count == 1 && pieces.count == 2 ? range.upperBound : b
            }
            guard range.contains(lo), range.contains(hi), lo <= hi else { return nil }
            out.formUnion(stride(from: lo, through: hi, by: step))
        }
        return out.isEmpty ? nil : out
    }

    private func dayMatches(_ c: DateComponents) -> Bool {
        let d = days.contains(c.day!), w = weekdays.contains(c.weekday! - 1)
        if anyDay && anyWeekday { return true }
        if anyDay { return w }
        if anyWeekday { return d }
        return d || w
    }

    /// The first matching minute strictly after `date`, or nil if none within five years
    /// (`0 0 30 2 *` never comes).
    ///
    /// Walks by whole days while the day is wrong and by hours while the hour is wrong, so a yearly
    /// schedule costs a few hundred steps, not the half-million minutes in between.
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard var t = calendar.date(bySetting: .second, value: 0, of: date) else { return nil }
        if t <= date { t = calendar.date(byAdding: .minute, value: 1, to: t)! }
        let limit = calendar.date(byAdding: .year, value: 5, to: date)!
        while t < limit {
            let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: t)
            if !months.contains(c.month!) || !dayMatches(c) {
                t = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: t)!)
                continue
            }
            if !hours.contains(c.hour!) {
                let top = calendar.date(bySettingHour: c.hour!, minute: 0, second: 0, of: t)!
                t = calendar.date(byAdding: .hour, value: 1, to: top)!
                continue
            }
            if minutes.contains(c.minute!) { return t }
            t = calendar.date(byAdding: .minute, value: 1, to: t)!
        }
        return nil
    }
}
