import Foundation

/// Where a client sits on the network.
///
/// Running GeoIP against `192.168.1.24` is meaningless, so the first thing the audit layer does
/// with an address is classify it — that decides whether "where is this client" is answered by a
/// geo database, by Tailscale's own identity, or not at all.
public enum IPScope: String, Sendable {
    case loopback
    case lan
    case tailscale
    case publicNet = "public"
    case unknown

    /// Tailscale hands out addresses from the CGNAT range 100.64.0.0/10.
    public static func classify(_ ip: String) -> IPScope {
        let address = ip.hasPrefix("::ffff:") ? String(ip.dropFirst(7)) : ip

        if address == "::1" || address.hasPrefix("127.") { return .loopback }
        if address.hasPrefix("fe80:") || address.hasPrefix("fc") || address.hasPrefix("fd") { return .lan }

        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return address.contains(":") ? .publicNet : .unknown
        }
        switch (parts[0], parts[1]) {
        case (10, _):                      return .lan
        case (192, 168):                   return .lan
        case (172, 16...31):               return .lan
        case (169, 254):                   return .lan          // link-local
        case (100, 64...127):              return .tailscale    // CGNAT — Tailscale in practice
        default:                           return .publicNet
        }
    }
}

/// The parts of an HTTP request the audit layer cares about.
///
/// FleetView's web server previously parsed only the request line and threw the rest away, which is
/// why "who opened the dashboard, from where" was unanswerable. Parsing lives here, in a pure type,
/// so the rules are pinned by tests rather than by reading the server.
public struct HTTPRequestHead: Equatable, Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    /// Header names are lowercased — HTTP field names are case-insensitive and clients disagree.
    public let headers: [String: String]
    public let cookies: [String: String]

    public init(method: String, path: String, query: [String: String],
                headers: [String: String], cookies: [String: String]) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.cookies = cookies
    }

    public init?(raw: String) {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
                .trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Repeated headers join with ", " as RFC 9110 prescribes.
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        let (path, query) = Self.splitPath(String(fields[1]))
        self.method = String(fields[0])
        self.path = path
        self.query = query
        self.headers = headers
        self.cookies = Self.parseCookies(headers["cookie"] ?? "")
    }

    public var userAgent: String? { headers["user-agent"] }
    public var acceptLanguage: String? { headers["accept-language"] }
    public var referer: String? { headers["referer"] }

    /// A proxy-supplied client address, when one is present and we are behind something that sets
    /// it. Only the first hop is meaningful; the rest is whatever the client felt like sending.
    public var forwardedFor: String? {
        headers["x-forwarded-for"]?.split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// FleetView's own tools identify themselves so their requests are attributed to the CLI rather
    /// than to an anonymous browser.
    public var cliTool: String? {
        if let explicit = headers["x-fleetview-actor"], !explicit.isEmpty { return explicit }
        guard let ua = userAgent, ua.hasPrefix("fleetctl/") else { return nil }
        return ua.split(separator: "/").dropFirst().first.map(String.init)
    }

    public static func splitPath(_ raw: String) -> (String, [String: String]) {
        guard let mark = raw.firstIndex(of: "?") else { return (raw, [:]) }
        let path = String(raw[raw.startIndex..<mark])
        var out: [String: String] = [:]
        for pair in raw[raw.index(after: mark)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = decode(String(kv[0]))
            out[key] = kv.count > 1 ? decode(String(kv[1])) : ""
        }
        return (path, out)
    }

    static func parseCookies(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}

/// Which endpoints are worth a log line each, and which are only worth counting.
///
/// The dashboard polls `/state` every 1.5s and `/conversation` every 3s. A phone left open for half
/// an hour is ~2,400 requests carrying no information; logging them per request would bury the
/// events that matter. Kubernetes' audit policy calls this omitting "high-frequency, low-value read
/// requests" — the counts still survive, in the periodic session rollup.
public enum WebPathPolicy {
    public static let polled: Set<String> = [
        "/state", "/panel-meta", "/panel-data", "/conversation", "/capture", "/tree",
    ]

    /// Static shell of the app: interesting the first time (it starts a session) and noise after.
    public static let documents: Set<String> = ["/", "/index.html", "/panel"]

    public static func isPolled(_ path: String) -> Bool { polled.contains(path) }

    /// Everything that changes something, sends input, or reveals an endpoint gets its own record.
    public static func isAudited(_ path: String) -> Bool {
        !isPolled(path) && !documents.contains(path)
    }
}

/// One browser's visit, as the audit log sees it.
public struct WebSession: Equatable, Sendable {
    public let id: String
    public var ip: String
    public var port: Int?
    public var scope: IPScope
    public var userAgent: String?
    public var acceptLanguage: String?
    public var geo: [String: AuditValue]
    public var startedAt: Date
    public var lastSeen: Date
    public var lastRollup: Date
    /// Counters since the last rollup, not since the session began.
    public var requests: Int
    public var bytesOut: Int
    public var byPath: [String: Int]
    public var totalRequests: Int
    public var selectedTerminal: String?

    public var duration: TimeInterval { lastSeen.timeIntervalSince(startedAt) }

    public var actor: AuditActor {
        AuditActor(kind: .web, id: id, name: Self.label(userAgent: userAgent),
                   sourceIP: ip, sourcePort: port, userAgent: userAgent, geo: geo)
    }

    /// "iPhone · Safari" — enough to recognise a device in a log without decoding a UA string.
    public static func label(userAgent: String?) -> String? {
        guard let ua = userAgent else { return nil }
        let device = ["iPhone", "iPad", "Android", "Macintosh", "Windows", "Linux"]
            .first { ua.contains($0) } ?? "device"
        let browser = ["Edg": "Edge", "OPR": "Opera", "Chrome": "Chrome", "Firefox": "Firefox",
                       "Safari": "Safari"].first { ua.contains($0.key) }?.value ?? "browser"
        return "\(device == "Macintosh" ? "Mac" : device) · \(browser)"
    }
}

/// Tracks browser sessions so the log records *visits*, not requests.
///
/// Time is injected rather than read from the clock so the rollup and expiry rules can be tested
/// without sleeping.
public final class WebSessionRegistry: @unchecked Sendable {
    public struct Observation {
        public let session: WebSession
        public let isNew: Bool
        /// Set when this request should also be recorded on its own (see `WebPathPolicy`).
        public let isAudited: Bool
    }

    private let lock = NSLock()
    private var sessions: [String: WebSession] = [:]
    private let idleTimeout: TimeInterval
    private let rollupInterval: TimeInterval

    public init(idleTimeout: TimeInterval = 1800, rollupInterval: TimeInterval = 300) {
        self.idleTimeout = idleTimeout
        self.rollupInterval = rollupInterval
    }

    public func session(_ id: String) -> WebSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[id]
    }

    /// Register a request. Returns the session and whether it had to be created.
    public func observe(id: String?,
                        ip: String,
                        port: Int? = nil,
                        userAgent: String?,
                        acceptLanguage: String? = nil,
                        path: String,
                        bytes: Int = 0,
                        now: Date) -> Observation {
        lock.lock(); defer { lock.unlock() }

        let key = id ?? Self.newID()
        var isNew = false
        var session: WebSession
        if var existing = sessions[key], now.timeIntervalSince(existing.lastSeen) < idleTimeout {
            existing.lastSeen = now
            session = existing
        } else {
            isNew = true
            session = WebSession(id: key, ip: ip, port: port, scope: IPScope.classify(ip),
                                 userAgent: userAgent, acceptLanguage: acceptLanguage, geo: [:],
                                 startedAt: now, lastSeen: now, lastRollup: now,
                                 requests: 0, bytesOut: 0, byPath: [:], totalRequests: 0,
                                 selectedTerminal: nil)
        }

        session.ip = ip
        if let port { session.port = port }
        session.scope = IPScope.classify(ip)
        if let userAgent { session.userAgent = userAgent }
        if let acceptLanguage { session.acceptLanguage = acceptLanguage }
        session.requests += 1
        session.totalRequests += 1
        session.bytesOut += bytes
        session.byPath[path, default: 0] += 1
        sessions[key] = session

        return Observation(session: session, isNew: isNew, isAudited: WebPathPolicy.isAudited(path))
    }

    public func setGeo(_ geo: [String: AuditValue], for id: String) {
        lock.lock(); defer { lock.unlock() }
        sessions[id]?.geo = geo
    }

    public func setSelection(_ terminal: String?, for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let previous = sessions[id]?.selectedTerminal
        sessions[id]?.selectedTerminal = terminal
        return previous
    }

    /// Sessions whose counters are due to be summarised. Counters reset as they are handed out, so
    /// each rollup covers exactly one window.
    public func dueRollups(now: Date) -> [WebSession] {
        lock.lock(); defer { lock.unlock() }
        var due: [WebSession] = []
        for (key, var session) in sessions where now.timeIntervalSince(session.lastRollup) >= rollupInterval {
            guard session.requests > 0 else {
                session.lastRollup = now
                sessions[key] = session
                continue
            }
            due.append(session)
            session.lastRollup = now
            session.requests = 0
            session.bytesOut = 0
            session.byPath = [:]
            sessions[key] = session
        }
        return due.sorted { $0.id < $1.id }
    }

    /// Sessions that have gone quiet, removed as they are returned.
    public func expire(now: Date) -> [WebSession] {
        lock.lock(); defer { lock.unlock() }
        let dead = sessions.values.filter { now.timeIntervalSince($0.lastSeen) >= idleTimeout }
        for session in dead { sessions.removeValue(forKey: session.id) }
        return dead.sorted { $0.id < $1.id }
    }

    public var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    public static func newID() -> String { "ws_" + Identifiers.ulid() }
}
