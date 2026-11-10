import Foundation

/// Preferences written before the bundle id changed (0.4.0 shipped as `ai.eigent.fleetview`; it is
/// `fun.puzhen.fleetview` since). UserDefaults is keyed on the bundle id, so the first launch of the
/// renamed app would otherwise start from nothing: the Mac's theme seed gone, a dismissed update
/// offered again. Copied once, never overwriting a value the new id already has; the old domain is
/// left in place so a rollback to the previous bundle still finds its settings.
enum LegacyDefaults {
    static let oldDomain = "ai.eigent.fleetview"
    private static let marker = "fv.migratedFromLegacyBundleId"

    static func migrate() {
        let d = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != oldDomain, !d.bool(forKey: marker) else { return }
        defer { d.set(true, forKey: marker) }
        guard let old = d.persistentDomain(forName: oldDomain), !old.isEmpty else { return }
        var copied = 0
        for (k, v) in old where d.object(forKey: k) == nil && !k.hasPrefix("NS") && !k.hasPrefix("Apple") {
            d.set(v, forKey: k)
            copied += 1
        }
        if copied > 0 { FV.log("defaults: carried \(copied) setting(s) over from \(oldDomain)") }
    }
}
