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

    /// Ask the browser for the device's own position. Costs nothing and sends nothing outward —
    /// the answer comes from the device — but it does put a permission prompt in front of whoever
    /// opens the dashboard, and it only works at all over HTTPS.
    var askBrowserLocation = true

    var promptPreview = true
    var promptPreviewChars = 120
    var webInputPreview = false

    /// `full` — the redacted command line. `argv0` — only the program name. `off` — neither.
    var shellCommand = "full"

    // No retention setting, by decision (2026-10-01): the audit log is kept forever, and nothing in
    // FleetView deletes a log file. The `retentionDays = 90` that used to sit here was never read.

    /// Ask GitHub whether a newer FleetView has been released. On by default because being a
    /// version behind is its own cost, but it IS an outbound call — one unauthenticated GET every
    /// six hours — so it is stated here and can be turned off.
    var updates = true

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
    var wantsBrowserLocation: Bool { wantsGeo && askBrowserLocation }
    var wantsPublicGeoLookup: Bool { geo == "city" && geoProvider != "none" }
}

extension AuditConfig {
    /// Each key read on its own, falling back to its default when absent.
    ///
    /// Synthesised decoding treats a missing key as an error even for a property with a default,
    /// so a logging.json that set only what it meant to change — `{"updates": false}`, exactly what
    /// UpdateCheck tells people to write — failed to decode as a whole, and `load()` quietly
    /// returned every default instead. The setting did nothing and nothing said so.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func take<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        take(.enabled, &enabled)
        take(.geo, &geo)
        take(.geoProvider, &geoProvider)
        take(.geoPrecisionDecimals, &geoPrecisionDecimals)
        take(.askBrowserLocation, &askBrowserLocation)
        take(.promptPreview, &promptPreview)
        take(.promptPreviewChars, &promptPreviewChars)
        take(.webInputPreview, &webInputPreview)
        take(.shellCommand, &shellCommand)
        take(.updates, &updates)
    }
}
