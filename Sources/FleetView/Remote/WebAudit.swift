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
    /// Terminal uuid → name. The request handler only ever sees a uuid in the query string, and a
    /// log that says "sent 40 characters to 3F2A9C4E" is a log nobody reads. Refreshed by the state
    /// layer, which is the only place that knows the names.
    private var terminalNames: [String: String] = [:]
    private let queue = DispatchQueue(label: "ai.eigent.fleetview.webaudit", qos: .utility)

    static let cookieName = "fv_ws"

    private var auditor: Auditor {
        lock.lock(); defer { lock.unlock() }
        return auditorRef
    }

    func updateTerminalNames(_ names: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        terminalNames = names
    }

    /// A named target for a terminal uuid taken from a query string.
    private func target(forTerminal id: String?) -> AuditTarget? {
        guard let id else { return nil }
        lock.lock()
        let name = terminalNames[id]
        lock.unlock()
        return AuditTarget(kind: "terminal", id: id, name: name)
    }

    /// Which agent a CLI call came from: project-manager sends the card it runs in
    /// (`FLEETVIEW_TERM_ID`) and its machine. Without it every call read "project-manager, from
    /// 127.0.0.1" — which of twenty agents had driven another was not in the log at all. A card on
    /// another Mac is named by its id and host; one on this Mac by its name too.
    private func caller(_ request: HTTPRequestHead?) -> [String: AuditValue] {
        var out: [String: AuditValue] = [:]
        if let id = request?.headers["x-fv-caller"]?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            out["caller.terminal.id"] = .string(id.uppercased())
            lock.lock()
            let name = terminalNames[id.uppercased()]
            lock.unlock()
            if let name { out["caller.terminal.name"] = .string(name) }
        }
        if let host = request?.headers["x-fv-caller-host"], !host.isEmpty { out["caller.host"] = .string(host) }
        return out
    }

    /// Reads a CLI makes of another card — its screen, its conversation — logged although the same
    /// endpoints polled by a browser are not: an agent looking at another is a deliberate act, and
    /// a rare one. `/state` stays out, since `wait` polls it every second.
    static let cliReads: Set<String> = ["/capture", "/conversation", "/tree"]

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
        // `/raw/<file>` carries a file path in the URL's path, so every file read that way would be a
        // path of its own in the session's per-path counts. One route, one name; the file is in facts.
        let path = (request?.path ?? "/").hasPrefix("/raw/") ? "/raw" : (request?.path ?? "/")
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
                               userAgent: session.userAgent, geo: session.geo,
                               extra: caller(request))
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
    ///
    /// `facts` is what only the handler knows — where an upload was written, how many bytes a
    /// download was, a command's exit code — and goes into the record as is.
    func finish(_ scope: Scope, status: String, bytes: Int, query: [String: String],
                facts: [String: AuditValue] = [:]) {
        let ok = status.hasPrefix("2")
        let duration = Int(Date().timeIntervalSince(scope.startedAt) * 1_000_000_000)

        guard ok else {
            // A refused request changes nothing, so the state diff cannot see it — and a refused
            // request is precisely what an audit trail exists for. Static shell paths are the
            // exception: browsers ask for /favicon.ico unprompted, and its 404 says nothing.
            guard !WebPathPolicy.isDocument(scope.path) else { return }
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
                                    ]).merging(facts) { own, _ in own },
                                    durationNanos: duration))
            return
        }

        guard scope.isAudited || (scope.actor.kind == .cli && Self.cliReads.contains(scope.path)),
              let event = requestEvent(scope, query: query, duration: duration, facts: facts) else { return }
        auditor.emit(event)
    }

    private let redaction = Redaction()

    /// `/pm`'s command line for the record, through the same redaction as a shell command line: a
    /// remote caller's `search` text or path is worth keeping, a token pasted into one is not.
    /// Built by the handler, so a command `/pm` refuses is logged with what was attempted.
    func pmFacts(argv: [String]) -> [String: AuditValue] {
        let clean = argv.map { redaction.apply(to: $0).text }
        var facts: [String: AuditValue] = ["pm.argv": .array(clean.map { .string($0) })]
        if clean != argv { facts["pm.redacted"] = .bool(true) }
        return facts
    }

    /// Only endpoints that change nothing get their own record. Anything that mutates state is
    /// already logged by the state diff, with this same actor attached — logging it here too would
    /// be the same fact written twice.
    private func requestEvent(_ scope: Scope, query: [String: String], duration: Int,
                              facts: [String: AuditValue]) -> AuditEvent? {
        let config = AuditConfig.current

        let terminal = target(forTerminal: query["id"])
        let named = terminal?.name.map { " \"\($0)\"" } ?? ""

        func event(_ name: String, _ message: String, _ data: [String: AuditValue],
                   categories: [String] = ["web"]) -> AuditEvent {
            AuditEvent(name: name, categories: categories, message: message,
                       actor: scope.actor, target: terminal, trace: scope.trace,
                       data: data, durationNanos: duration)
        }

        switch scope.path {
        case "/open":
            return event("fleetview.web.terminal_attached", "attached to\(named)",
                         [:], categories: ["session"])

        case "/type":
            let text = query["text"] ?? ""
            var data: [String: AuditValue] = [
                "text.chars": .int(text.count),
                "text.sha256": .string(AuditDigest.short(text)),
                "enter": .bool(query["enter"] == "1"),
            ]
            // An agent driving another (project-manager) is logged word for word, what one agent
            // told another being the whole of the record — through the same redaction as a command
            // line, so a token pasted into it is not. A person typing from the phone keeps the
            // preview rule: it ends up in the transcript anyway, and is off by default.
            if scope.actor.kind == .cli, !text.isEmpty {
                let clean = redaction.apply(to: text).text
                data["text"] = .string(clean)
                if clean != text { data["text.redacted"] = .bool(true) }
            } else if config.webInputPreview, !text.isEmpty {
                data["text.preview"] = .string(String(text.prefix(config.promptPreviewChars)))
            }
            return event("fleetview.web.input_sent", "sent \(text.count) characters to\(named)", data)

        case "/capture":
            return event("fleetview.web.screen_read", "read the screen of\(named)",
                         AuditValue.compact(["lines": query["lines"].map { .string($0) }]), categories: ["session"])

        case "/conversation":
            return event("fleetview.web.conversation_read", "read the conversation of\(named)",
                         AuditValue.compact(["limit": query["limit"].map { .string($0) }]), categories: ["session"])

        case "/tree":
            return event("fleetview.web.tree_read", "read the session tree of\(named)", [:], categories: ["session"])

        case "/commits":
            return event("fleetview.web.card_commits_read", "listed the commits and changes of\(named)", [:],
                         categories: ["session"])

        case "/writers":
            return event("fleetview.web.writers_read", "asked which card wrote \(query["path"] ?? "?")",
                         AuditValue.compact(["path": query["path"].map { .string($0) }]), categories: ["session"])

        case "/repo":
            return event("fleetview.web.repo_read", "read the commits and changes of \(query["path"] ?? "?")",
                         AuditValue.compact(["path": query["path"].map { .string($0) },
                                             "sha": query["sha"].map { .string($0) }]), categories: ["session"])

        case "/key":
            return event("fleetview.web.key_sent", "sent key \(query["k"] ?? "?") to\(named)",
                         AuditValue.compact(["key": query["k"].map { .string($0) }]))

        case "/scroll":
            return event("fleetview.web.scrolled", "scrolled \(query["dir"] ?? "up")\(named)",
                         AuditValue.compact(["dir": query["dir"].map { .string($0) }]))

        case "/select":
            let selected = query["id"].flatMap { $0.isEmpty ? nil : $0 }
            let previous = registry.setSelection(selected, for: scope.sessionID)
            guard previous != selected else { return nil }     // re-selecting the same thing is not news
            if selected != nil {
                return event("fleetview.web.terminal_selected", "opened\(named)",
                             AuditValue.compact(["selection.from": previous.map { .string($0) },
                                                 "view": query["view"].map { .string($0) }]),
                             categories: ["session"])
            }
            let leaving = target(forTerminal: previous)?.name.map { " \"\($0)\"" } ?? ""
            return AuditEvent(name: "fleetview.web.terminal_deselected",
                              categories: ["session"],
                              message: "closed the view of\(leaving)",
                              actor: scope.actor,
                              target: target(forTerminal: previous),
                              trace: scope.trace,
                              data: AuditValue.compact(["selection.from": previous.map { .string($0) }]),
                              durationNanos: duration)

        case "/geo":
            // A location the *device* reported, not one inferred from an address. Rounded before it
            // is stored: a neighbourhood answers "where was this", and an exact fix in a log file
            // is a liability.
            let consent = query["consent"] ?? "unknown"
            var data: [String: AuditValue] = ["consent": .string(consent)]
            if let reason = query["reason"] { data["reason"] = .string(reason) }

            if consent == "granted", let lat = Double(query["lat"] ?? ""), let lon = Double(query["lon"] ?? "") {
                let decimals = config.geoPrecisionDecimals
                let rounded = AuditValue.object(["lat": .double(Self.round(lat, decimals)),
                                                 "lon": .double(Self.round(lon, decimals))])
                data["client.geo.location"] = rounded
                if let accuracy = Int(query["acc"] ?? "") { data["accuracy_m"] = .int(accuracy) }
                // Carried by every later event from this session, so the whole visit is placed.
                var geo = registry.session(scope.sessionID)?.geo ?? [:]
                geo["client.geo.location"] = rounded
                geo["client.geo.source"] = .string("device")
                registry.setGeo(geo, for: scope.sessionID)
                return event("fleetview.web.session_geo", "device reported its location", data)
            }
            // Recorded too: "we have no fix, and here is why" beats an unexplained absence.
            return event("fleetview.web.session_geo",
                         "no device location (\(consent))", data)

        case "/ask":
            // A side query never reaches the transcript, so if it is not recorded here it is
            // recorded nowhere.
            let question = query["q"] ?? ""
            var data: [String: AuditValue] = [
                "question.chars": .int(question.count),
                "question.sha256": .string(AuditDigest.short(question)),
            ]
            if scope.actor.kind == .cli, !question.isEmpty {
                let clean = redaction.apply(to: question).text
                data["question"] = .string(clean)
                if clean != question { data["question.redacted"] = .bool(true) }
            } else if config.promptPreview, !question.isEmpty {
                data["question.preview"] = .string(String(question.prefix(config.promptPreviewChars)))
            }
            return event("fleetview.web.ask", "asked\(named) a side question", data,
                         categories: ["session"])

        case "/read":
            // The one endpoint that hands a project's own source out over the network. What was read
            // is not recoverable from anything else, so it is recorded here or nowhere.
            return event("fleetview.web.file_read", "read \(query["path"] ?? "?")",
                         AuditValue.compact(["path": query["path"].map { .string($0) },
                                             "download": .bool(query["dl"] == "1")]))

        case "/raw":
            // The same disclosure as /read, opened in a tab of its own — and a rendered page pulls
            // its stylesheets and scripts through here too, each one a file read.
            let path = facts["path"]?.displayString ?? "?"
            return event("fleetview.web.file_read", "read \(path) (raw)",
                         ["path": .string(path), "raw": .bool(true)], categories: ["web", "file"])

        case "/save":
            // A file on the Mac rewritten from a browser. The app state never changes, so this record
            // is the only trace of who wrote what into it — before and after, by hash.
            let path = facts["path"]?.displayString ?? query["path"] ?? "?"
            return event("fleetview.web.file_saved", "saved \(path)", facts, categories: ["web", "file"])

        // The four below changed no app state, so the diff never saw them; until 2026-10-01 they
        // were only a count in the five-minute rollup, with no file name or command attached.

        case "/upload":
            let name = facts["file.name"]?.displayString ?? "a file"
            let saved = facts["file.path"]?.displayString.split(separator: "/").last.map(String.init) ?? "?"
            return event("fleetview.web.file_uploaded", "uploaded \(name) → \(saved)", facts,
                         categories: ["web", "file"])

        case "/file":
            let name = facts["file.name"]?.displayString ?? query["id"] ?? "?"
            return AuditEvent(name: "fleetview.web.file_downloaded", categories: ["web", "file"],
                              message: "took \(name) from the outbox",
                              actor: scope.actor,
                              // The terminal whose agent offered the file, when the offer says.
                              target: target(forTerminal: facts["file.from"]?.displayString),
                              trace: scope.trace, data: facts, durationNanos: duration)

        case "/browse":
            return event("fleetview.web.dir_browsed", "listed \(query["path"] ?? "?")",
                         AuditValue.compact(["path": query["path"].map { .string($0) }])
                            .merging(facts) { own, _ in own },
                         categories: ["web", "file"])

        case "/pm":
            // Another Mac running `project-manager -u <this one>`: what it asked, and what it got.
            var words: [String] = []
            if case .array(let argv)? = facts["pm.argv"] { words = argv.map(\.displayString) }
            return event("fleetview.web.pm_run", "ran project-manager \(words.joined(separator: " "))",
                         facts, categories: ["web", "process"])

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

    private static func round(_ value: Double, _ decimals: Int) -> Double {
        let factor = pow(10.0, Double(max(0, decimals)))
        return (value * factor).rounded() / factor
    }

    private static func cookieHeader(_ id: String) -> String {
        "\(cookieName)=\(id); Path=/; Max-Age=2592000; SameSite=Lax"
    }
}
