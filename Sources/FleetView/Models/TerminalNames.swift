import Foundation

/// Card names are unique — across the board and the drawer of removed cards, ignoring case.
///
/// The name is how a card is found again: ⌘K, the drawer, `project-manager`. On 2026-10-30, 53
/// names were each held by more than one card, 144 rows between them — `FleetView-2` eight times,
/// because the default number counted the cards open *now* and started again from 1 once a
/// project's cards had been removed, and a duplicate or fork of `X` was always `X ⑂`. Looking a
/// card up by name meant guessing between identical rows.
///
/// A name that is taken gets a number after it — `tasks (2)`, `tasks (3)` — short enough to stay on
/// the card whole (the first version put the time there, and a narrow card cut it off: the one part
/// that told two cards apart was the part not shown). Names given a time on 2026-10-30, when the
/// duplicates already on disk were resolved, keep it.
enum TerminalNames {

    /// What two names are compared by. Case-folded because search is: two names that one query
    /// cannot tell apart are the same name for the purpose of finding a card.
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `name` when nothing holds it, else the next free `name (n)`, from 2. A name that already ends
    /// in a number counts on from its root: asking for `tasks (2)` when it is taken gives `tasks (3)`,
    /// not `tasks (2) (2)`.
    static func unique(_ name: String, taken: Set<String>) -> String {
        if !taken.contains(key(name)) { return name }
        // Trimmed first: `tasks ` would otherwise become `tasks  (2)`, a name that compares as
        // different and reads as the same.
        var root = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = root.range(of: #" \(\d+\)$"#, options: .regularExpression) { root = String(root[..<m.lowerBound]) }
        var n = 2
        while taken.contains(key("\(root) (\(n))")) { n += 1 }
        return "\(root) (\(n))"
    }

    /// A name and the part of it that tells it from another card's — a number, or the time an older
    /// duplicate was given — so that part can be drawn whole while the rest gives way.
    static func split(_ name: String) -> (base: String, suffix: String?) {
        for pattern in [#" \(\d+\)$"#, #" · \d\d-\d\d \d\d:\d\d(:\d\d)?( #\d+)?$"#] {
            if let r = name.range(of: pattern, options: .regularExpression), r.lowerBound > name.startIndex {
                return (String(name[..<r.lowerBound]), String(name[r.lowerBound...]))
            }
        }
        return (name, nil)
    }

    /// One card's hold on a name.
    struct Claim {
        let id: UUID
        let name: String
    }

    /// The names that already clash, resolved: the first claim to a name keeps it and every later
    /// one gets the next number. Aligned with `claims`; nil where a name stays as it is.
    ///
    /// The same id twice is one card listed in two places (on the board and still in the drawer),
    /// not a clash.
    static func deduplicated(_ claims: [Claim]) -> [String?] {
        var taken = Set(claims.map { key($0.name) })
        var holder: [String: UUID] = [:]
        return claims.map { c in
            let k = key(c.name)
            guard let first = holder[k] else { holder[k] = c.id; return nil }
            if first == c.id { return nil }
            let name = unique(c.name, taken: taken)
            taken.insert(key(name))
            holder[key(name)] = c.id
            return name
        }
    }

    /// `n` for a default name, `<project>-<n>`; nil for any other name.
    static func defaultNumber(_ name: String, project: String) -> Int? {
        let prefix = project + "-"
        guard name.hasPrefix(prefix), let n = Int(name.dropFirst(prefix.count)), n > 0 else { return nil }
        return n
    }
}
