import Foundation
import FleetViewAudit

/// Audit middleware for the web dashboard.
///
/// One wrapper around request handling buys attribution for *every* endpoint — the ones that exist
/// today and the ones added later. A handler that mutates state needs no logging code of its own:
/// the state diff fires with `actor = web`, carrying this session's IP, device and location.
///
/// What it does per request:
///  * identifies the browser session (an `fv_ws` cookie, issued on first contact)
///  * resolves where the client is (see `GeoResolver`)
///  * installs the ambient `AuditContext` the state layer reads
///  * records the request itself only when it is worth a line — polls are counted, not logged
///
/// Thread-safe and deliberately not main-actor: it runs on the server's own queue, before and after
/// the hop onto the main actor.
final class WebAudit: @unchecked Sendable {
    static let shared = WebAudit()

    struct Scope {
        let sessionID: String
        let actor: AuditActor
        let trace: AuditTrace
        let path: String
        let isAudited: Bool
        let setCookie: String?
        let startedAt: Date
    }

    private let registry = WebSessionRegistry()
    private let lock = NSLock()
    private var auditorRef: Auditor = .disabled
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ai.eigent.fleetview.webaudit", qos: .utility)

    static let cookieName = "fv_ws"

    private var auditor: Auditor {
        lock.lock(); defer { lock.unlock() }
        return auditorRef
    }

    /// Called once at launch, from the main actor.
    func start(auditor: Auditor) {
        lock.lock()
        auditorRef = auditor
        lock.unlock()

        // Periodic housekeeping: summarise the poll traffic of live sessions, and close out ones
        // that have gone quiet. Both are how the log stays a record of *visits* rather than of
        // several thousand identical GETs.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in self?.sweep() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for session in registry.expire(now: Date().addingTimeInterval(86_400)) {
            emitSessionEnded(session, reason: "server_stop")
        }
    }

    // MARK: - Per request

    func begin(request: HTTPRequestHead?, ip: String, port: Int?) -> Scope {
        let now = Date()
        let path = request?.path ?? "/"
        // A proxy hop wins over the socket address, but only when we are actually behind one.
        let clientIP = request?.forwardedFor ?? ip

        let observed = registry.observe(id: request?.cookies[Self.cookieName],
                                        ip: clientIP,
                                        port: port,
                                        userAgent: request?.userAgent,
                                        acceptLanguage: request?.acceptLanguage,
                                        path: path,
                                        now: now)
        var session = observed.session

        // Recomputed every request, not just on the first: resolution is non-blocking, so a cold
        // Tailscale cache means the peer's identity only lands a request or two later.
        let geo = GeoResolver.shared.fields(ip: clientIP, acceptLanguage: request?.acceptLanguage)
        if geo != session.geo {
            registry.setGeo(geo, for: session.id)
            session.geo = geo
        }

        // FleetView's own scripts hit the same endpoints; without this they would be logged as
        // anonymous browsers.
        var actor = session.actor
        if let tool = request?.cliTool {
            actor = AuditActor(kind: .cli, id: session.id, name: tool, cliTool: tool,
                               sourceIP: session.ip, sourcePort: session.port,
                               userAgent: session.userAgent, geo: session.geo)
        }

        let trace = AuditTrace(id: Identifiers.ulid(now: now),
                               requestID: Identifiers.ulid(now: now),
                               webSessionID: session.id)

        if observed.isNew {
            emitSessionStarted(session, actor: actor, trace: trace, firstPath: path)
        }

        let needsCookie = request?.cookies[Self.cookieName] != session.id
        return Scope(sessionID: session.id,
                     actor: actor,
                     trace: trace,
                     path: path,
                     isAudited: observed.isAudited,
                     setCookie: needsCookie ? Self.cookieHeader(session.id) : nil,
                     startedAt: now)
    }

    /// Called after the response is produced. Emits at most one record.
    func finish(_ scope: Scope, status: String, bytes: Int, query: [String: String]) {
        let ok = status.hasPrefix("2")
        let duration = Int(Date().timeIntervalSince(scope.startedAt) * 1_000_000_000)

        guard ok else {
            // A refused request changes nothing, so the state diff cannot see it — and a refused
            // request is precisely what an audit trail exists for.
            auditor.emit(AuditEvent(name: "fleetview.web.request_denied",
                                    kind: .alert,
                                    categories: ["web"],
                                    outcome: .failure,
                                    message: "\(scope.path) → \(status)",
                                    actor: scope.actor,
                                    trace: scope.trace,
                                    data: AuditValue.compact([
                                        "http.path": .string(scope.path),
                                        "http.status": .string(status),
                                        "id": query["id"].map { .string($0) },
                                    ]),
                                    durationNanos: duration))
            return
        }

        guard scope.isAudited, let event = requestEvent(scope, query: query, duration: duration) else { return }
        auditor.emit(event)
    }

    /// Only endpoints that change nothing get their own record. Anything that mutates state is
    /// already logged by the state diff, with this same actor attached — logging it here too would
    /// be the same fact written twice.
    private func requestEvent(_ scope: Scope, query: [String: String], duration: Int) -> AuditEvent? {
        let config = AuditConfig.current

        func event(_ name: String, _ message: String, _ data: [String: AuditValue],
                   categories: [String] = ["web"]) -> AuditEvent {
            AuditEvent(name: name, categories: categories, message: message,
                       actor: scope.actor, trace: scope.trace, data: data, durationNanos: duration)
        }

        switch scope.path {
        case "/open":
            return event("fleetview.web.terminal_attached", "attached to a terminal",
                         AuditValue.compact(["terminal.id": query["id"].map { .string($0) }]),
                         categories: ["session"])

        case "/type":
            let text = query["text"] ?? ""
            var data: [String: AuditValue] = [
                "text.chars": .int(text.count),
                "text.sha256": .string(AuditDigest.short(text)),
                "enter": .bool(query["enter"] == "1"),
            ]
            if let id = query["id"] { data["terminal.id"] = .string(id) }
            // The text ends up in the agent's transcript anyway; a preview here is convenience,
            // and off by default.
            if config.webInputPreview, !text.isEmpty {
                data["text.preview"] = .string(String(text.prefix(config.promptPreviewChars)))
            }
            return event("fleetview.web.input_sent", "sent \(text.count) characters", data)

        case "/key":
            return event("fleetview.web.key_sent", "sent key \(query["k"] ?? "?")",
                         AuditValue.compact(["key": query["k"].map { .string($0) },
                                             "terminal.id": query["id"].map { .string($0) }]))

        case "/scroll":
            return event("fleetview.web.scrolled", "scrolled \(query["dir"] ?? "up")",
                         AuditValue.compact(["dir": query["dir"].map { .string($0) },
                                             "terminal.id": query["id"].map { .string($0) }]))

        case "/select":
            let terminal = query["id"].flatMap { $0.isEmpty ? nil : $0 }
            let previous = registry.setSelection(terminal, for: scope.sessionID)
            guard previous != terminal else { return nil }     // re-selecting the same thing is not news
            if let terminal {
                return event("fleetview.web.terminal_selected", "opened a terminal",
                             AuditValue.compact(["terminal.id": .string(terminal),
                                                 "selection.from": previous.map { .string($0) },
                                                 "view": query["view"].map { .string($0) }]),
                             categories: ["session"])
            }
            return event("fleetview.web.terminal_deselected", "closed the terminal view",
                         AuditValue.compact(["selection.from": previous.map { .string($0) }]),
                         categories: ["session"])

        case "/ask":
            // A side query never reaches the transcript, so if it is not recorded here it is
            // recorded nowhere.
            let question = query["q"] ?? ""
            var data: [String: AuditValue] = [
                "question.chars": .int(question.count),
                "question.sha256": .string(AuditDigest.short(question)),
            ]
            if let id = query["id"] { data["terminal.id"] = .string(id) }
            if config.promptPreview, !question.isEmpty {
                data["question.preview"] = .string(String(question.prefix(config.promptPreviewChars)))
            }
            return event("fleetview.web.ask", "asked a side question", data, categories: ["session"])

        default:
            // Endpoints that mutate state (/action, /new, /note) are covered by the diff.
            return nil
        }
    }

    // MARK: - Sessions

    private func emitSessionStarted(_ session: WebSession, actor: AuditActor,
                                    trace: AuditTrace, firstPath: String) {
        var where_ = session.scope.rawValue
        if let node = session.geo["fleetview.web.peer.node"]?.displayString { where_ = node }
        else if let city = session.geo["client.geo.city_name"]?.displayString { where_ = city }

        auditor.emit(AuditEvent(name: "fleetview.web.session_started",
                                categories: ["authentication", "web"],
                                message: "web session from \(where_) (\(session.ip))",
                                actor: actor,
                                trace: trace,
                                data: AuditValue.compact([
                                    "first_path": .string(firstPath),
                                    "scope": .string(session.scope.rawValue),
                                ])))
    }

    private func emitSessionEnded(_ session: WebSession, reason: String) {
        auditor.emit(AuditEvent(name: "fleetview.web.session_ended",
                                categories: ["authentication", "web"],
                                message: "web session ended (\(reason))",
                                actor: session.actor,
                                data: [
                                    "reason": .string(reason),
                                    "requests": .int(session.totalRequests),
                                    "duration_ms": .int(Int(session.duration * 1000)),
                                ]))
    }

    private func sweep() {
        let now = Date()
        for session in registry.dueRollups(now: now) {
            auditor.emit(AuditEvent(name: "fleetview.web.session_activity",
                                    kind: .state,
                                    categories: ["web"],
                                    message: "\(session.requests) requests in the last window",
                                    actor: session.actor,
                                    data: [
                                        "requests": .int(session.requests),
                                        "bytes_out": .int(session.bytesOut),
                                        "by_path": .object(session.byPath.mapValues { .int($0) }),
                                    ]))
        }
        for session in registry.expire(now: now) {
            emitSessionEnded(session, reason: "idle_timeout")
        }
    }

    private static func cookieHeader(_ id: String) -> String {
        "\(cookieName)=\(id); Path=/; Max-Age=2592000; SameSite=Lax"
    }
}
