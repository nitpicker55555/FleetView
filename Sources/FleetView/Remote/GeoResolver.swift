import Foundation
import FleetViewAudit

/// Answers "where is this client" for FleetView's actual deployment, which is a LAN and a tailnet —
/// not the public internet.
///
/// Running a geo database against `192.168.1.24` returns nothing useful, so resolution is tiered:
///
///  1. **Network scope** — loopback / LAN / Tailscale / public. Always available, and by itself
///     often the answer you wanted ("that was me on the same wifi").
///  2. **Tailscale identity** — `tailscale status --json` maps a CGNAT address to a node name, the
///     logged-in user, its OS and its DERP relay region. For a tailnet client this is *more*
///     precise than GeoIP and costs no network call.
///  3. **Browser hints** — `Accept-Language` from the request. On a LAN this often says more about
///     where somebody is than an IP ever could.
///  4. **Public GeoIP** — only for genuinely public addresses, only when explicitly enabled, since
///     it means handing a visitor's IP to a third party.
///
/// Precise browser geolocation is deliberately absent: `navigator.geolocation` requires a secure
/// context, and the dashboard is served over plain HTTP on a LAN address, so the browser refuses
/// regardless of what we ask for. It becomes possible behind `tailscale serve` (real TLS), which is
/// the documented upgrade path.
final class GeoResolver: @unchecked Sendable {
    static let shared = GeoResolver()

    private let lock = NSLock()
    private var tailscalePeers: [String: [String: AuditValue]] = [:]
    private var tailscaleFetchedAt: Date?
    private var refreshInFlight = false
    private var publicCache: [String: (fields: [String: AuditValue], at: Date)] = [:]
    private let queue = DispatchQueue(label: "ai.eigent.fleetview.geo", qos: .utility)

    private var hostGeoCache: [String: AuditValue] = [:]
    private var hostGeoFetchedAt: Date?
    private var hostFetchInFlight = false

    private let peerTTL: TimeInterval = 60
    private let publicTTL: TimeInterval = 86_400
    private let hostTTL: TimeInterval = 3_600

    /// Everything known synchronously. Never blocks on the network.
    func fields(ip: String, acceptLanguage: String?) -> [String: AuditValue] {
        let config = AuditConfig.current
        guard config.wantsGeo else { return [:] }

        let scope = IPScope.classify(ip)
        var out: [String: AuditValue] = ["fleetview.web.scope": .string(scope.rawValue)]

        if let language = acceptLanguage?.split(separator: ",").first.map(String.init) {
            out["fleetview.web.accept_language"] = .string(language)
        }

        // The machine's own timezone. Free, never leaves the Mac, and on a LAN it says more about
        // where somebody is sitting than any address does.
        out["fleetview.host.timezone"] = .string(TimeZone.current.identifier)

        switch scope {
        case .tailscale:
            if let peer = tailscalePeer(for: ip) {
                for (key, value) in peer { out[key] = value }
            }
        case .publicNet:
            if let cached = cachedPublic(ip) {
                for (key, value) in cached { out[key] = value }
            } else if config.wantsPublicGeoLookup {
                resolvePublicInBackground(ip)     // available on the *next* request from this address
            }
        case .loopback, .lan:
            // A private address is not routable, so there is nothing to geolocate. What *can* be
            // said is where this Mac's own connection comes out — the client is on the same wifi,
            // so the network's location is a truthful answer to "where was this". Recorded under
            // `host.geo` rather than `client.geo` so nobody mistakes it for the device's own fix.
            for (key, value) in hostGeo() { out[key] = value }
        case .unknown:
            break
        }
        return out
    }

    /// This Mac's egress location, refreshed hourly. Requires an explicit opt-in because resolving
    /// it means asking a third party where our own public address is.
    private func hostGeo() -> [String: AuditValue] {
        guard AuditConfig.current.wantsPublicGeoLookup else { return [:] }
        lock.lock()
        let cached = hostGeoCache
        let fresh = hostGeoFetchedAt.map { Date().timeIntervalSince($0) < hostTTL } ?? false
        let inFlight = hostFetchInFlight
        if !fresh && !inFlight { hostFetchInFlight = true }
        lock.unlock()

        if !fresh && !inFlight {
            queue.async { [weak self] in
                guard let self else { return }
                // An empty host resolves our own public address, then its location.
                let fields = Self.lookupPublic("").map { pairs in
                    Dictionary(uniqueKeysWithValues: pairs.map { key, value in
                        (key.replacingOccurrences(of: "client.", with: "host."), value)
                    })
                } ?? [:]
                self.lock.lock()
                self.hostGeoCache = fields
                self.hostGeoFetchedAt = Date()
                self.hostFetchInFlight = false
                self.lock.unlock()
            }
        }
        return cached
    }

    // MARK: - Tailscale

    /// Peer identity for a CGNAT address, from cache. Never blocks: `tailscale status` forks a
    /// process, and this is called on the web server's *serial* queue — waiting on a fork there
    /// would stall every other pending connection. A stale cache triggers a background refresh and
    /// the answer lands on a later request.
    private func tailscalePeer(for ip: String) -> [String: AuditValue]? {
        lock.lock()
        let fresh = tailscaleFetchedAt.map { Date().timeIntervalSince($0) < peerTTL } ?? false
        let cached = tailscalePeers[ip]
        let refreshing = refreshInFlight
        if !fresh && !refreshing { refreshInFlight = true }
        lock.unlock()

        if !fresh && !refreshing {
            queue.async { [weak self] in
                let peers = Self.readTailscaleStatus()
                guard let self else { return }
                self.lock.lock()
                self.tailscalePeers = peers
                self.tailscaleFetchedAt = Date()
                self.refreshInFlight = false
                self.lock.unlock()
            }
        }
        return cached
    }

    private static func readTailscaleStatus() -> [String: [String: AuditValue]] {
        guard let binary = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [:] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }

        var out: [String: [String: AuditValue]] = [:]
        var nodes: [[String: Any]] = []
        if let peers = root["Peer"] as? [String: Any] {
            nodes.append(contentsOf: peers.values.compactMap { $0 as? [String: Any] })
        }
        if let selfNode = root["Self"] as? [String: Any] { nodes.append(selfNode) }

        let users = root["User"] as? [String: Any] ?? [:]
        for node in nodes {
            var fields: [String: AuditValue] = [:]
            if let name = node["HostName"] as? String { fields["fleetview.web.peer.node"] = .string(name) }
            if let os = node["OS"] as? String, !os.isEmpty { fields["fleetview.web.peer.os"] = .string(os) }
            if let relay = node["Relay"] as? String, !relay.isEmpty {
                // The DERP region a peer is homed to is a coarse but genuine location signal.
                fields["fleetview.web.peer.derp_region"] = .string(relay)
            }
            if let userID = node["UserID"] as? Int,
               let user = users["\(userID)"] as? [String: Any],
               let login = user["LoginName"] as? String {
                fields["fleetview.web.peer.user"] = .string(login)
            }
            for address in (node["TailscaleIPs"] as? [String]) ?? [] {
                out[address] = fields
            }
        }
        return out
    }

    // MARK: - Public addresses

    private func cachedPublic(_ ip: String) -> [String: AuditValue]? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = publicCache[ip], Date().timeIntervalSince(entry.at) < publicTTL else { return nil }
        return entry.fields
    }

    /// Resolve asynchronously and cache. The first request from a new public address is logged
    /// without a city; every later one has it. That is the right trade: a logging subsystem must
    /// never make a request wait on a third party.
    private func resolvePublicInBackground(_ ip: String) {
        lock.lock()
        let alreadyQueued = publicCache[ip] != nil
        if !alreadyQueued { publicCache[ip] = (fields: [:], at: Date()) }   // debounce
        lock.unlock()
        guard !alreadyQueued else { return }

        queue.async { [weak self] in
            guard let self, let fields = Self.lookupPublic(ip) else { return }
            self.lock.lock()
            self.publicCache[ip] = (fields: fields, at: Date())
            self.lock.unlock()
        }
    }

    /// An empty `ip` asks the service to resolve whatever address the request came from — which is
    /// this Mac's own egress address.
    private static func lookupPublic(_ ip: String) -> [String: AuditValue]? {
        let decimals = AuditConfig.current.geoPrecisionDecimals
        guard let url = URL(string: "http://ip-api.com/json/\(ip)?fields=status,countryCode,regionName,city,lat,lon,timezone,as") else { return nil }

        var result: [String: AuditValue]?
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["status"] as? String) == "success" else { return }
            var fields: [String: AuditValue] = [:]
            if let country = json["countryCode"] as? String { fields["client.geo.country_iso_code"] = .string(country) }
            if let region = json["regionName"] as? String { fields["client.geo.region_name"] = .string(region) }
            if let city = json["city"] as? String { fields["client.geo.city_name"] = .string(city) }
            if let timezone = json["timezone"] as? String { fields["client.geo.timezone"] = .string(timezone) }
            if let lat = json["lat"] as? Double, let lon = json["lon"] as? Double {
                // Rounded on purpose: a neighbourhood is enough to answer "where was this", and an
                // exact coordinate in a log file is a liability.
                fields["client.geo.location"] = .object([
                    "lat": .double(Self.round(lat, decimals)),
                    "lon": .double(Self.round(lon, decimals)),
                ])
            }
            if let asn = json["as"] as? String { fields["client.as.organization"] = .string(asn) }
            result = fields
        }
        task.resume()
        _ = done.wait(timeout: .now() + 4)
        return result
    }

    private static func round(_ value: Double, _ decimals: Int) -> Double {
        let factor = pow(10.0, Double(max(0, decimals)))
        return (value * factor).rounded() / factor
    }
}
