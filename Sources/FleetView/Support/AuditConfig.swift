import Foundation

/// Tunables for the audit log, read from `~/.fleetview/logging.json` if it exists.
///
/// The defaults are the privacy-conservative ones: no outbound geo lookups, no web input previews,
/// and shell commands recorded in full but redacted. Anything that could send data off the machine
/// has to be turned on deliberately.
struct AuditConfig: Codable {
    var enabled = true

    /// `off` — no location at all.
    /// `local` — network scope, Tailscale peer identity, and the browser's own language/timezone
    ///           hints. All of it comes from the machine itself; nothing leaves.
    /// `city` — additionally resolves *public* addresses to a city through `provider`, which is a
    ///          network call to a third party. Off by default for that reason.
    var geo = "local"
    var geoProvider = "none"          // none | ipapi
    var geoPrecisionDecimals = 2      // ≈1 km, so a coordinate is a neighbourhood, not an address

    var promptPreview = true
    var promptPreviewChars = 120
    var webInputPreview = false

    /// `full` — the redacted command line. `argv0` — only the program name. `off` — neither.
    var shellCommand = "full"

    var retentionDays = 90

    static var current: AuditConfig = load()

    static func load() -> AuditConfig {
        let url = FV.supportDir.appendingPathComponent("logging.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AuditConfig.self, from: data) else {
            return AuditConfig()
        }
        return config
    }

    var wantsGeo: Bool { geo != "off" }
    var wantsPublicGeoLookup: Bool { geo == "city" && geoProvider != "none" }
}
