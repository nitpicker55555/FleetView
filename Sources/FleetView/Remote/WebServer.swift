import FleetViewAudit
import FleetViewFiles
import Foundation
import Network

/// A live snapshot of the dashboard, serialized to the web page as JSON (`GET /state`).
struct WebSnapshot: Codable {
    struct Term: Codable {
        let id: String
        let name: String
        let projectId: String
        let clusterId: String?
        let status: String        // raw TermStatus (drives the dot colour)
        let statusLabel: String   // human label ("running", "needs you", …)
        let agent: String         // "claude" / "codex" / ""
        let prompt: String
        let tokens: Int
        let canOpen: Bool         // is a live session attachable over the web right now?
        let done: Bool            // subtask marked done
        let idle: Int             // seconds since last real interaction, -1 if never
        let running: Int          // seconds the current run has been going, -1 if it isn't running
        let lastRun: Int          // seconds the last finished run took, -1 if it has never run
        let finished: Int         // seconds since a run last ended back at idle, -1 if it is not idle after one
        let cwd: String
        let transcript: String?   // agent conversation-history file (Claude/Codex), if a hook reported it
        let window: String        // its desktop window: "open", "hidden" (agent running unseen), "none"
        /// How many triggers it has, and how many of them are timed (see AgentTrigger) — the chip.
        /// Left out when there are none, so a board without any is byte-for-byte what it was.
        let trig: Int?
        let trigTimed: Int?
    }
    struct Proj: Codable { let id: String; let name: String; let path: String }
    struct Clust: Codable { let id: String; let name: String }
    struct NoteJ: Codable { let id: String; let text: String }   // doubles as the web quick-command list

    let projects: [Proj]
    let terminals: [Term]
    let clusters: [Clust]
    let notes: [NoteJ]
    let working: Int
    let needs: Int
    let remoteOK: Bool            // tmux + ttyd present → terminals are interactive
    let remoteHint: String        // install hint when they're not
    let askGeo: Bool              // whether the page should ask the device for its position
    let fleetTriggers: Int        // triggers FleetView itself runs (the header's ⚡ count)
    let fleetTriggersRunning: Int
    /// The appearance the desktop window is drawing right now. The dashboard follows the Mac rather
    /// than the phone's own dark mode: it is a mirror of that window, and the two disagreeing reads
    /// as a bug rather than a preference.
    let dark: Bool
}

/// A tiny, dependency-free HTTP/1.1 server (Network.framework) that serves the web dashboard.
/// One page plus a handful of JSON endpoints; every request is answered once and the connection is
/// closed. All app state is read on the main actor via `AppState.webResponse`; the handlers kept
/// here are the ones whose work is file I/O rather than state, so they stay off it.
final class WebServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ai.eigent.fleetview.web")
    private(set) var port: Int = 0
    weak var app: AppState?

    /// Listen on `preferredPort`, or the next port that will have us, on all interfaces.
    ///
    /// A relaunch — a deploy, or the self-update handing off — can come up while the instance it
    /// replaces is still letting go of its listener, and the dashboard used to move to 8081 for good,
    /// stranding every phone bookmarked on 8080. The fix was to wait up to 3 s for the port when it
    /// was this app's last time, probing with a plain bind first. That was not enough: on 2026-10-02,
    /// relaunched straight after a quit with the load average at 34, the dashboard came up on 8081
    /// again, and nothing held 8080 by the time anyone looked. So the probe is gone — the listener
    /// itself is the test — and our own port gets 20 s, retried off the main thread, before the
    /// next one is taken. The app finishes launching meanwhile; only the dashboard waits.
    func start(preferredPort: Int = 8080) {
        stateLock.lock(); stopped = false; stateLock.unlock()
        let lastPort = (try? String(contentsOf: FV.webPortFile, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        // What the board shows until the listener says otherwise. It is what we will almost always
        // end up on, and a 0 would hide the panel and the dashboard links in the meantime.
        port = preferredPort
        portCeiling = preferredPort + 100
        queue.async { self.listen(on: preferredPort, ownPort: lastPort == preferredPort, tries: 0) }
    }

    /// Guards `listener` and `stopped`: the listen runs on `queue`, `stop` on the main thread at quit.
    private let stateLock = NSLock()
    /// While a listen is retried or the next port tried, `stop` must be able to end it.
    private var stopped = false
    private var isStopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopped }

    private func listen(on p: Int, ownPort: Bool, tries: Int) {
        guard !isStopped, p < portCeiling, let nwPort = NWEndpoint.Port(rawValue: UInt16(p)) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: nwPort) else {
            listen(on: p + 1, ownPort: false, tries: 0)
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.receive(conn, buffer: Data())
        }
        // Holds `l` until it fails or is stopped; a listener that is ready is the server from then on.
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.isStopped else { l.cancel(); return }
                DispatchQueue.main.async { self.port = p }
                try? "\(p)".write(to: FV.webPortFile, atomically: true, encoding: .utf8)   // let fleetctl find us
                if p + 100 != self.portCeiling || tries > 0 {
                    FV.log("web: listening on \(p)" + (tries > 0 ? " after \(tries) retries" : ""))
                }
            case .failed, .waiting:
                l.stateUpdateHandler = nil
                l.cancel()
                if ownPort && tries < Self.ownPortRetries {
                    self.queue.asyncAfter(deadline: .now() + 0.5) {
                        self.listen(on: p, ownPort: true, tries: tries + 1)
                    }
                } else {
                    self.listen(on: p + 1, ownPort: false, tries: 0)
                }
            default:
                break
            }
        }
        stateLock.lock(); listener = l; stateLock.unlock()
        l.start(queue: queue)
    }

    /// 0.5 s apart: 20 s for the port this app had last time to come free.
    private static let ownPortRetries = 40
    /// How far the search for a free port goes, as before: a hundred ports past the preferred one.
    private var portCeiling = 0

    func stop() {
        stateLock.lock()
        stopped = true
        let l = listener
        listener = nil
        stateLock.unlock()
        l?.stateUpdateHandler = nil
        l?.cancel()
    }

    // MARK: - Request handling

    /// Biggest request body accepted. Phone photos land around 2-5 MB; this leaves room for a
    /// full-resolution one without letting a bad request hold memory indefinitely.
    private static let maxBody = 25 * 1024 * 1024

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.receiveBody(conn, header: buf.subdata(in: buf.startIndex..<end.lowerBound),
                                 body: buf.subdata(in: end.upperBound..<buf.endIndex))
                return
            }
            if isComplete || error != nil || buf.count > 1_000_000 { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    /// Headers are complete; keep reading until the declared body has arrived. Everything except an
    /// upload has no body and routes on the first pass — this used to return at the end of the
    /// headers and drop whatever followed them.
    private func receiveBody(_ conn: NWConnection, header: Data, body: Data) {
        let head = HTTPRequestHead(raw: String(data: header, encoding: .utf8) ?? "")
        let expected = Int(head?.headers["content-length"] ?? "") ?? 0
        if expected > Self.maxBody {
            send(conn, status: "413 Payload Too Large", type: "text/plain", body: Data("too large".utf8))
            return
        }
        if body.count >= expected {
            route(conn, header: header, body: body)
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = body
            if let data { buf.append(data) }
            if buf.count >= expected { self.route(conn, header: header, body: buf); return }
            // A client that hangs up mid-upload leaves a partial image; drop it rather than save it.
            if isComplete || error != nil { conn.cancel(); return }
            self.receiveBody(conn, header: header, body: buf)
        }
    }

    private func route(_ conn: NWConnection, header: Data, body: Data) {
        // The whole header block is parsed now, not just the request line: the client address,
        // User-Agent and session cookie are what make every downstream event attributable, and they
        // used to be thrown away here.
        let raw = String(data: header, encoding: .utf8) ?? ""
        let request = HTTPRequestHead(raw: raw)
        let path = request?.path ?? "/"
        let params = request?.query ?? [:]
        let client = Self.clientAddress(conn)
        let scope = WebAudit.shared.begin(request: request, ip: client.ip, port: client.port)

        if path == "/ping" { handlePing(conn, client.ip, params, scope); return }  // never the main actor
        if path == "/ask" { handleAsk(conn, params, scope); return }   // long-running; off the main thread
        if path == "/pm" { handlePM(conn, params, scope); return }     // runs a script; off it too
        if path == "/type", params["wait"] == "1" { handleTypeAndWait(conn, params, scope); return }
        if path == "/upload" {                                         // writes a file; no app state
            handleUpload(conn, request, body, params, scope); return
        }
        if path == "/save" {                                           // writes a file; no app state
            handleSave(conn, request, body, params, scope); return
        }
        if path.hasPrefix("/raw/") { handleRaw(conn, path, params, scope); return }
        if path == "/files" { handleFileList(conn, params, scope); return }
        if path == "/file" { handleFileGet(conn, params, scope); return }
        if path == "/browse" { handleBrowse(conn, params, scope); return }
        if path == "/read" { handleRead(conn, params, scope); return }
        if path == "/conversation" { handleConversation(conn, params, scope); return }
        if path == "/share" { handleShare(conn, request, body, params, scope); return }  // network; off it
        if path == "/fleet-triggers" || path.hasPrefix("/fleet-triggers/") {          // has a body
            handleFleetTriggers(conn, request, body, params, scope); return
        }
        if path == "/commits" { handleCommits(conn, params, scope); return }
        if path == "/writers" { handleWriters(conn, params, scope); return }
        if path == "/repo" { handleRepo(conn, params, scope); return }  // parsing; off it
        if path == "/capture" { handleCapture(conn, params, scope); return }            // tmux; off it
        if path == "/triggers" { handleTriggers(conn, params, scope); return }          // transcript; off it

        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data())
                return
            }
            MainActor.assumeIsolated {
                // Everything this request provokes — including state changes in handlers that know
                // nothing about logging — is attributed to this browser, at this address.
                let (status, type, body) = AuditContext.with(scope.actor, trace: scope.trace) {
                    app.webResponse(path: path, query: params)
                }
                WebAudit.shared.finish(scope, status: status, bytes: body.count, query: params)
                self.queue.async {
                    self.send(conn, status: status, type: type, body: body, setCookie: scope.setCookie)
                }
            }
        }
    }

    /// The peer address of an inbound connection. `remoteEndpoint` is only populated once the path
    /// is established, so `endpoint` is the fallback.
    static func clientAddress(_ conn: NWConnection) -> (ip: String, port: Int?) {
        let endpoint = conn.currentPath?.remoteEndpoint ?? conn.endpoint
        guard case .hostPort(let host, let port) = endpoint else { return ("unknown", nil) }
        return (hostString(host), Int(port.rawValue))
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        let raw: String
        switch host {
        case .ipv4(let address): raw = "\(address)"
        case .ipv6(let address): raw = "\(address)"
        case .name(let name, _): raw = name
        @unknown default: raw = "unknown"
        }
        // IPv6 literals arrive with a scope zone ("fe80::1%en0"); the address is the part we want.
        return raw.split(separator: "%").first.map(String.init) ?? raw
    }

    /// GET /ping — the page's latency probe, behind its signal indicator.
    ///
    /// Answered here, on the server's queue, so the round trip it times is the network's: `/state`
    /// waits for the main actor, and a busy board would read as a bad connection. The answer says
    /// how this device reaches the Mac — same machine, LAN, or Tailscale direct or relayed — which
    /// is most of what explains the number.
    private func handlePing(_ conn: NWConnection, _ ip: String, _ query: [String: String],
                            _ scope: WebAudit.Scope) {
        let body = (try? JSONSerialization.data(withJSONObject: GeoResolver.shared.connection(ip: ip)))
            ?? Data("{}".utf8)
        WebAudit.shared.finish(scope, status: "200 OK", bytes: body.count, query: query)
        send(conn, status: "200 OK", type: "application/json", body: body, setCookie: scope.setCookie)
    }

    /// GET /ask?id=&q= — a "BTW" side query: ask the agent using its context without touching the live
    /// session. The spec lookup is quick (main actor); the agent subprocess (~10-30s) runs on a global
    /// queue so it never blocks the UI or other requests.
    private func handleAsk(_ conn: NWConnection, _ query: [String: String], _ scope: WebAudit.Scope) {
        func answer(_ status: String, _ type: String, _ body: Data) {
            WebAudit.shared.finish(scope, status: status, bytes: body.count, query: query)
            send(conn, status: status, type: type, body: body, setCookie: scope.setCookie)
        }
        guard let s = query["id"], let id = UUID(uuidString: s), let q = query["q"], !q.isEmpty else {
            answer("400 Bad Request", "text/plain", Data("bad request".utf8)); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data()); return
            }
            let spec = MainActor.assumeIsolated { app.askSpec(id) }
            guard let spec else {
                answer("409 Conflict", "text/plain", Data("no agent session for this terminal yet".utf8))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let reply = RemoteServer.ask(spec, question: q)
                answer("200 OK", "text/plain; charset=utf-8", Data(reply.utf8))
            }
        }
    }

    /// GET /conversation?id=&limit= — a terminal's transcript as chat, which renders with native
    /// scrolling: how you read history on a phone, where the terminal mirror cannot scroll a TUI.
    /// The main actor only says which transcript and screen; reading them happens here.
    /// `&full=1` is the whole file, every message — what sharing the whole conversation sends.
    private func handleConversation(_ conn: NWConnection, _ query: [String: String],
                                    _ scope: WebAudit.Scope) {
        func answer(_ status: String, _ body: Data) {
            WebAudit.shared.finish(scope, status: status, bytes: body.count, query: query)
            send(conn, status: status, type: "application/json", body: body, setCookie: scope.setCookie)
        }
        guard let s = query["id"], let id = UUID(uuidString: s) else {
            answer("400 Bad Request", Data(#"{"error":"bad id"}"#.utf8)); return
        }
        let limit = min(400, Int(query["limit"] ?? "") ?? 120)
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data()); return
            }
            let spec = MainActor.assumeIsolated { app.conversationSpec(id) }
            DispatchQueue.global(qos: .userInitiated).async {
                answer("200 OK", spec.respond(limit: limit, whole: query["full"] == "1"))
            }
        }
    }

    /// `/fleet-triggers…` (see AppState.fleetTriggerResponse). Its own route only because `add`
    /// carries a JSON body and the generic path does not pass one on; the work is on the main actor.
    private func handleFleetTriggers(_ conn: NWConnection, _ head: HTTPRequestHead?, _ body: Data,
                                     _ query: [String: String], _ scope: WebAudit.Scope) {
        let path = head?.path ?? "/fleet-triggers"
        let method = head?.method.uppercased() ?? "GET"
        let caller = head?.headers["x-fv-caller"]
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data()); return
            }
            let (status, data) = MainActor.assumeIsolated {
                AuditContext.with(scope.actor, trace: scope.trace) {
                    app.fleetTriggerResponse(path: path, method: method, query: query, body: body, caller: caller)
                }
            }
            WebAudit.shared.finish(scope, status: status, bytes: data.count, query: query)
            self.queue.async {
                self.send(conn, status: status, type: "application/json", body: data, setCookie: scope.setCookie)
            }
        }
    }

    /// POST /share?title= — the body is a finished conversation page (the web chat builds it); it
    /// goes to the share service in `~/.fleetview/share.json` and the public link comes back.
    /// POST /share?del=<id> takes one down. Off the main actor: it is a network round trip.
    private func handleShare(_ conn: NWConnection, _ head: HTTPRequestHead?, _ body: Data,
                             _ query: [String: String], _ scope: WebAudit.Scope) {
        @Sendable func answer(_ status: String, _ payload: [String: Any],
                              facts: [String: AuditValue] = [:]) {
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            WebAudit.shared.finish(scope, status: status, bytes: data.count, query: query, facts: facts)
            send(conn, status: status, type: "application/json", body: data, setCookie: scope.setCookie)
        }
        guard head?.method.uppercased() == "POST" else {
            answer("405 Method Not Allowed", ["error": "POST only"]); return
        }
        if let id = query["del"], !id.isEmpty {
            ShareService.withdraw(id: id) { result in
                switch result {
                case .success: answer("200 OK", ["ok": true], facts: ["share.id": .string(id)])
                case .failure(let f): answer("502 Bad Gateway", ["error": f.message],
                                             facts: ["share.id": .string(id)])
                }
            }
            return
        }
        guard !body.isEmpty, String(data: body, encoding: .utf8) != nil else {
            answer("400 Bad Request", ["error": "the body has to be the page, as UTF-8"]); return
        }
        let title = query["title"] ?? ""
        // What went out, and where it can be read: the record of what this LAN made public.
        let facts: [String: AuditValue] = ["share.title": .string(title), "file.bytes": .int(body.count),
                                           "file.sha256": .string(AuditDigest.sha256(data: body))]
        ShareService.publish(html: body, title: title) { result in
            switch result {
            case .success(let p):
                answer("200 OK", ["id": p.id, "url": p.url],
                       facts: facts.merging(["share.id": .string(p.id), "share.url": .string(p.url)]) { $1 })
            case .failure(let f):
                let status = f.isNotConfigured ? "503 Service Unavailable" : "502 Bad Gateway"
                answer(status, ["error": f.message, "unconfigured": f.isNotConfigured], facts: facts)
            }
        }
    }

    /// GET /commits?id= — one card's commits, in every repository, and the files it wrote that are
    /// still uncommitted (AppState.gitReport). The ledger catches up first, so a commit from a few
    /// minutes ago is in it; one answered in the last half minute is not matched yet.
    private func handleCommits(_ conn: NWConnection, _ query: [String: String], _ scope: WebAudit.Scope) {
        func answer(_ status: String, _ body: Data) {
            WebAudit.shared.finish(scope, status: status, bytes: body.count, query: query)
            send(conn, status: status, type: "application/json", body: body, setCookie: scope.setCookie)
        }
        guard let s = query["id"], let id = UUID(uuidString: s) else {
            answer("400 Bad Request", Data(#"{"error":"bad id"}"#.utf8)); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data()); return
            }
            let (book, card) = MainActor.assumeIsolated { () -> (AppState.CardBook, (String, String)?) in
                let t = app.terminals.first { $0.id == id }
                return (app.cardBook(), t.map { t in (t.name, app.projects.first { $0.id == t.projectId }?.name ?? "") })
            }
            guard let card else { answer("404 Not Found", Data(#"{"error":"no such terminal"}"#.utf8)); return }
            MainActor.assumeIsolated {
                app.refreshCommitLedger {
                    DispatchQueue.global(qos: .userInitiated).async {
                        answer("200 OK", AppState.gitReport(card: id, name: card.0, project: card.1, book))
                    }
                }
            }
        }
    }

    /// GET /writers?path= — which card wrote a file, or each uncommitted file under a folder
    /// (AppState.writersReport). An absolute path on this machine.
    private func handleWriters(_ conn: NWConnection, _ query: [String: String], _ scope: WebAudit.Scope) {
        func answer(_ status: String, _ body: Data) {
            WebAudit.shared.finish(scope, status: status, bytes: body.count, query: query)
            send(conn, status: status, type: "application/json", body: body, setCookie: scope.setCookie)
        }
        guard let path = query["path"], path.hasPrefix("/") else {
            answer("400 Bad Request", Data(#"{"error":"give an absolute path"}"#.utf8)); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data()); return
            }
            MainActor.assumeIsolated {
                let book = app.cardBook()
                app.refreshCommitLedger {
                    DispatchQueue.global(qos: .userInitiated).async { answer("200 OK", AppState.writersReport(path: path, book)) }
                }
            }
        }
    }

    /// GET /repo?path=&limit=&sha= — a repository's newest commits (or one) with the card that made
    /// each, and its uncommitted files with the card that wrote each (AppState.repoReport).
    private func handleRepo(_ conn: NWConnection, _ query: [String: String], _ scope: WebAudit.Scope) {
        func answer(_ status: String, _ body: Data) {
            WebAudit.shared.finish(scope, status: status, bytes: body.count, query: query)
            send(conn, status: status, type: "application/json", body: body, setCookie: scope.setCookie)
        }
        guard let path = query["path"], path.hasPrefix("/") else {
            answer("400 Bad Request", Data(#"{"error":"give an absolute path"}"#.utf8)); return
        }
        let limit = min(500, max(1, Int(query["limit"] ?? "") ?? 30))
        let sha = query["sha"].flatMap { $0.isEmpty ? nil : $0 }
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data()); return
            }
            MainActor.assumeIsolated {
                let book = app.cardBook()
                app.refreshCommitLedger {
                    DispatchQueue.global(qos: .userInitiated).async {
                        answer("200 OK", AppState.repoReport(path: path, limit: limit, sha: sha, book))
                    }
                }
            }
        }
    }

    /// GET /triggers?id= — what will make a terminal's agent act on its own (see AgentTrigger),
    /// with what its transcript adds: whole prompts, fire counts, which one-shots are /loop wakeups.
    private func handleTriggers(_ conn: NWConnection, _ query: [String: String], _ scope: WebAudit.Scope) {
        func answer(_ status: String, _ body: Data) {
            WebAudit.shared.finish(scope, status: status, bytes: body.count, query: query)
            send(conn, status: status, type: "application/json", body: body, setCookie: scope.setCookie)
        }
        guard let s = query["id"], let id = UUID(uuidString: s) else {
            answer("400 Bad Request", Data(#"{"error":"bad id"}"#.utf8)); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data()); return
            }
            guard let spec = MainActor.assumeIsolated({ app.triggersSpec(id) }) else {
                answer("404 Not Found", Data(#"{"error":"no such terminal"}"#.utf8)); return
            }
            DispatchQueue.global(qos: .userInitiated).async { answer("200 OK", spec.respond()) }
        }
    }

    /// GET /capture?id=&lines= — a terminal's screen and recent scrollback as text, for
    /// `project-manager show`, its submit check and its error scan.
    private func handleCapture(_ conn: NWConnection, _ query: [String: String], _ scope: WebAudit.Scope) {
        func answer(_ status: String, _ type: String, _ body: Data) {
            WebAudit.shared.finish(scope, status: status, bytes: body.count, query: query)
            send(conn, status: status, type: type, body: body, setCookie: scope.setCookie)
        }
        guard let s = query["id"], let id = UUID(uuidString: s) else {
            answer("400 Bad Request", "text/plain", Data("bad id".utf8)); return
        }
        let lines = Int(query["lines"] ?? "") ?? 200
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data()); return
            }
            let (tmux, session) = MainActor.assumeIsolated {
                (app.remote.tmuxPath, RemoteServer.sessionName(for: id))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let text = tmux.flatMap { RemoteServer.capturePane($0, session: session, lines: lines) } ?? ""
                answer("200 OK", "text/plain; charset=utf-8", Data(text.utf8))
            }
        }
    }

    /// GET /pm?argv=<JSON array>&color=0|1&origin=<caller's URL for this instance> — run one of
    /// project-manager's file-reading commands here and answer `{"code","stdout","stderr"}`. See
    /// PMRunner for why the script runs rather than a Swift copy of it.
    private func handlePM(_ conn: NWConnection, _ query: [String: String], _ scope: WebAudit.Scope) {
        let port = self.port
        let argv = (query["argv"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                    as? [String]) ?? []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (status, result) = PMRunner.run(argv: argv, port: port, color: query["color"] == "1",
                                                origin: query["origin"],
                                                caller: scope.actor.extra["caller.terminal.id"]?.displayString,
                                                callerHost: scope.actor.extra["caller.host"]?.displayString)
            let body = (try? JSONEncoder().encode(result)) ?? Data(#"{"code":1}"#.utf8)
            WebAudit.shared.finish(scope, status: status, bytes: body.count, query: query,
                                   facts: WebAudit.shared.pmFacts(argv: argv).merging([
                                       "pm.exit_code": .int(Int(result.code)),
                                       "pm.stdout_bytes": .int(result.stdout.utf8.count),
                                       "pm.stderr_bytes": .int(result.stderr.utf8.count),
                                   ]) { own, _ in own })
            self?.send(conn, status: status, type: "application/json", body: body,
                       setCookie: scope.setCookie)
        }
    }

    /// GET /type?…&wait=1 — the same typing as plain `/type`, answered only once the submit has been
    /// checked: `{"ok":true,"submit":"submitted"|"stuck"|"sent"|"typed"|"superseded"}`.
    ///
    /// Plain `/type` answers before tmux has even run, so "ok" there only ever meant "queued" — and
    /// a prompt left sitting in Codex's composer looked exactly like one that ran. A caller that
    /// reports back (`project-manager send`, the web's Send) needs the difference. The wait is
    /// spent on the terminal's write queue, never on the main actor. An older FleetView ignores
    /// `wait` and answers `{"ok":true}` at once, so callers treat a missing `submit` as "unknown".
    private func handleTypeAndWait(_ conn: NWConnection, _ query: [String: String],
                                   _ scope: WebAudit.Scope) {
        @Sendable func answer(_ status: String, _ body: Data) {
            WebAudit.shared.finish(scope, status: status, bytes: body.count, query: query)
            Self.write(conn, status: status, type: "application/json", body: body,
                       setCookie: scope.setCookie)
        }
        guard let s = query["id"], let id = UUID(uuidString: s) else {
            answer("400 Bad Request", Data(#"{"error":"bad id"}"#.utf8)); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data())
                return
            }
            MainActor.assumeIsolated {
                AuditContext.with(scope.actor, trace: scope.trace) {
                    app.webType(id, text: query["text"] ?? "", enter: query["enter"] == "1") { outcome in
                        answer("200 OK", Data(#"{"ok":true,"submit":"\#(outcome.rawValue)"}"#.utf8))
                    }
                }
            }
        }
    }

    /// POST /upload — the raw bytes of one image, answered with the absolute path it was written to.
    ///
    /// The point is to get a picture from a phone into a prompt: the file lands on this Mac and only
    /// its path is typed into the composer, so the agent opens it exactly as it would one you had
    /// dropped into a desktop terminal.
    ///
    /// The name is always generated here and never taken from the client. That is what the caller
    /// asked for, and it also means a request cannot choose where it writes: no path separators, no
    /// traversal, no collision with an existing upload. The type is decided by sniffing the bytes
    /// rather than believing Content-Type, so a mislabelled photo still gets the right extension and
    /// anything that isn't an image is refused outright.
    private func handleUpload(_ conn: NWConnection, _ head: HTTPRequestHead?, _ body: Data,
                              _ query: [String: String], _ scope: WebAudit.Scope) {
        func answer(_ status: String, _ type: String, _ data: Data, facts: [String: AuditValue] = [:]) {
            WebAudit.shared.finish(scope, status: status, bytes: data.count, query: query, facts: facts)
            send(conn, status: status, type: type, body: data, setCookie: scope.setCookie)
        }
        guard head?.method.uppercased() == "POST" else {
            answer("405 Method Not Allowed", "text/plain", Data("POST only".utf8)); return
        }
        guard !body.isEmpty else {
            answer("400 Bad Request", "application/json", Data(#"{"error":"empty body"}"#.utf8)); return
        }
        // Any file, not just an image: a log, a CSV, a PDF are all things you might want to hand an
        // agent from a phone. The extension is what an agent keys off, so it is worth getting right —
        // sniffed when the bytes say what they are, otherwise taken from the client's filename and
        // scrubbed to a bare token. The basename is still always ours.
        let ext = Self.imageExtension(body) ?? Self.safeExtension(query["name"]) ?? "bin"
        let url = FV.uploadsDir.appendingPathComponent("\(UUID().uuidString.lowercased()).\(ext)")
        do {
            try FileManager.default.createDirectory(at: FV.uploadsDir, withIntermediateDirectories: true)
            try body.write(to: url, options: .atomic)
        } catch {
            FV.log("upload failed: \(error.localizedDescription)")
            answer("500 Internal Server Error", "application/json",
                   Data(#"{"error":"could not save"}"#.utf8)); return
        }
        FV.log("upload: \(body.count) bytes → \(url.lastPathComponent)")
        let payload = ["path": url.path, "name": url.lastPathComponent, "bytes": "\(body.count)"]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        // The client's own filename is kept for the record only; the file on disk is named by us.
        answer("200 OK", "application/json", data,
               facts: AuditValue.compact(["file.name": query["name"].map { .string($0) },
                                          "file.path": .string(url.path),
                                          "file.bytes": .int(body.count),
                                          "file.sha256": .string(AuditDigest.sha256(data: body))]))
    }

    // MARK: - Outbox (agent → phone)

    /// GET /files — what agents have handed over, newest first.
    ///
    /// The push side is deliberately not an endpoint: `fleetview-send` runs on this Mac and writes
    /// straight into the outbox, so handing over a file needs no server, no request size limit, and
    /// works while the dashboard has never been opened. This only reads what is there.
    private func handleFileList(_ conn: NWConnection, _ query: [String: String], _ scope: WebAudit.Scope) {
        var out: [[String: Any]] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FV.outboxDir.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            let url = FV.outboxDir.appendingPathComponent(name)
            guard let d = try? Data(contentsOf: url),
                  let meta = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let id = meta["id"] as? String, let ext = meta["ext"] as? String else { continue }
            // Drop an entry whose blob has been removed by hand rather than serving a broken row.
            guard FileManager.default.fileExists(
                atPath: FV.outboxDir.appendingPathComponent("\(id).\(ext)").path) else { continue }
            // `from` stays a terminal id. Naming it is the page's job — it already polls /state for
            // every terminal, and this handler runs on the server's queue, not the main actor.
            out.append(meta)
        }
        out.sort { ($0["ts"] as? String ?? "") > ($1["ts"] as? String ?? "") }
        let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("[]".utf8)
        WebAudit.shared.finish(scope, status: "200 OK", bytes: data.count, query: query)
        send(conn, status: "200 OK", type: "application/json", body: data, setCookie: scope.setCookie)
    }

    /// GET /file?id=<uuid> — the bytes of one offered file.
    private func handleFileGet(_ conn: NWConnection, _ query: [String: String], _ scope: WebAudit.Scope) {
        func answer(_ status: String, _ type: String, _ data: Data, disposition: String? = nil,
                    facts: [String: AuditValue] = [:]) {
            WebAudit.shared.finish(scope, status: status, bytes: data.count, query: query, facts: facts)
            send(conn, status: status, type: type, body: data, setCookie: scope.setCookie,
                 disposition: disposition)
        }
        // A UUID and nothing else: the id indexes into a directory, so it must not be able to be a
        // path. Rebuilding it from the parsed value drops anything that isn't one.
        guard let raw = query["id"], let uuid = UUID(uuidString: raw) else {
            answer("400 Bad Request", "text/plain", Data("bad id".utf8)); return
        }
        let id = uuid.uuidString.lowercased()
        guard let d = try? Data(contentsOf: FV.outboxDir.appendingPathComponent("\(id).json")),
              let meta = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let ext = meta["ext"] as? String,
              let body = try? Data(contentsOf: FV.outboxDir.appendingPathComponent("\(id).\(ext)"))
        else {
            answer("404 Not Found", "text/plain", Data("no such file".utf8)); return
        }
        let name = (meta["name"] as? String) ?? "\(id).\(ext)"
        let type = Self.mimeType(forExtension: ext)
        // Known types open in the browser (the point is usually to LOOK at it on the phone);
        // anything else downloads, under the name the agent gave it.
        let inline = type != nil && query["dl"] != "1"
        answer("200 OK", type ?? "application/octet-stream", body,
               disposition: "\(inline ? "inline" : "attachment"); filename=\"\(Self.headerSafe(name))\"",
               facts: AuditValue.compact(["file.id": .string(id),
                                          "file.name": .string(name),
                                          "file.bytes": .int(body.count),
                                          "file.from": (meta["from"] as? String).map { .string($0) },
                                          "download": .bool(!inline)]))
    }

    // MARK: - Project file browser

    /// The project directories a browse request may look inside. Read where app state lives and
    /// handed back on the server's own queue: everything that follows is file I/O, and the main
    /// actor is busy drawing the desktop window.
    private func projectRoots(_ conn: NWConnection, _ work: @escaping ([String]) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data())
                return
            }
            let roots = MainActor.assumeIsolated { app.projects.map(\.path) }
            self.queue.async { work(roots) }
        }
    }

    /// Resolve a requested path and confine it to one of the project directories, returning it with
    /// the root it belongs to — which is where "go up" has to stop.
    ///
    /// The page only ever asks for paths it was given by `/state`, but a query parameter is the
    /// client's to write, so the check is made here rather than assumed. Symlinks are resolved on
    /// both sides first: a link inside a project is otherwise a door straight out of it, and a plain
    /// prefix test walks through it without noticing.
    static func confine(_ raw: String, roots: [String]) -> (url: URL, root: URL)? {
        guard !raw.isEmpty else { return nil }
        let target = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        for root in roots where !root.isEmpty {
            let base = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath()
            if target.path == base.path || target.path.hasPrefix(base.path + "/") { return (target, base) }
        }
        return nil
    }

    /// GET /browse?path=<dir> — one directory listing, so a project can be walked from the phone.
    private func handleBrowse(_ conn: NWConnection, _ query: [String: String], _ scope: WebAudit.Scope) {
        projectRoots(conn) { [weak self] roots in
            guard let self else { return }
            func answer(_ status: String, _ data: Data, facts: [String: AuditValue] = [:]) {
                WebAudit.shared.finish(scope, status: status, bytes: data.count, query: query,
                                       facts: facts)
                self.send(conn, status: status, type: "application/json", body: data,
                          setCookie: scope.setCookie)
            }
            guard let raw = query["path"], let target = Self.confine(raw, roots: roots) else {
                answer("403 Forbidden", Data(#"{"error":"that path is not inside a project"}"#.utf8)); return
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.url.path, isDirectory: &isDir),
                  isDir.boolValue else {
                answer("404 Not Found", Data(#"{"error":"no such directory"}"#.utf8)); return
            }
            let listed = Self.listing(target.url, root: target.root)
            answer("200 OK", listed.data,
                   facts: ["dir.root": .string(target.root.path),
                           "dir.entries": .int(listed.entries),
                           "dir.truncated": .bool(listed.truncated)])
        }
    }

    /// One directory as JSON: directories first, then files, each with what the row shows.
    ///
    /// Capped, because a project contains `node_modules` and a phone does not want ninety thousand
    /// rows — and the cap is reported rather than silently applied, so a short list can be trusted
    /// to be the whole list. The names are sorted before the cap so which 3000 you get is stable.
    static func listing(_ dir: URL, root: URL) -> (data: Data, entries: Int, truncated: Bool) {
        struct Row { let name: String; let dir: Bool; let size: Int; let mtime: Int }
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let capped = all.prefix(3000)
        var rows: [Row] = []
        for name in capped {
            let u = dir.appendingPathComponent(name)
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey,
                                                    .contentModificationDateKey])
            rows.append(Row(name: name, dir: v?.isDirectory ?? false, size: v?.fileSize ?? 0,
                            mtime: Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)))
        }
        // Two passes rather than one sort: Swift's sort is not stable, and a `dir` comparison alone
        // would shuffle the name order inside each half.
        let ordered = rows.filter(\.dir) + rows.filter { !$0.dir }
        let payload: [String: Any] = [
            "path": dir.path,
            "root": root.path,
            "parent": dir.path == root.path ? "" : dir.deletingLastPathComponent().path,
            "truncated": all.count > capped.count,
            "entries": ordered.map { ["name": $0.name, "dir": $0.dir, "size": $0.size, "mtime": $0.mtime] },
        ]
        return ((try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8),
                all.count, all.count > capped.count)
    }

    /// GET /read?path=<file> — the bytes of one file inside a project.
    ///
    /// Source is what this is for, so anything without a binary type of its own comes back as UTF-8
    /// text. Images and PDFs keep their own type and the page just shows them; a file that turns out
    /// to be binary is refused with its size, and `?dl=1` fetches it as a download instead.
    private func handleRead(_ conn: NWConnection, _ query: [String: String], _ scope: WebAudit.Scope) {
        projectRoots(conn) { [weak self] roots in
            guard let self else { return }
            func answer(_ status: String, _ type: String, _ data: Data, disposition: String? = nil,
                        headers: [(String, String)] = []) {
                WebAudit.shared.finish(scope, status: status, bytes: data.count, query: query)
                self.send(conn, status: status, type: type, body: data, setCookie: scope.setCookie,
                          disposition: disposition, headers: headers)
            }
            guard let raw = query["path"], let target = Self.confine(raw, roots: roots) else {
                answer("403 Forbidden", "text/plain; charset=utf-8",
                       Data("that path is not inside a project".utf8)); return
            }
            let url = target.url
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                answer("404 Not Found", "text/plain; charset=utf-8", Data("no such file".utf8)); return
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            let type = Self.mimeType(forExtension: url.pathExtension)
            let binary = type != nil && !(type!.hasPrefix("text/") || type! == "application/json")

            if binary || query["dl"] == "1" {
                guard size <= Self.maxBody else {
                    answer("413 Payload Too Large", "text/plain; charset=utf-8",
                           Data("\(size / 1_048_576) MB is too large to send".utf8)); return
                }
                guard let body = try? Data(contentsOf: url) else {
                    answer("500 Internal Server Error", "text/plain; charset=utf-8",
                           Data("could not read it".utf8)); return
                }
                let inline = query["dl"] != "1" && type != nil
                answer("200 OK", type ?? "application/octet-stream", body,
                       disposition: "\(inline ? "inline" : "attachment")"
                                  + "; filename=\"\(Self.headerSafe(url.lastPathComponent))\"")
                return
            }

            // A prefix, not the file: a 200 MB log opened by accident should cost one read of half a
            // megabyte, not the whole thing in memory on its way to a phone.
            let limit = 512 * 1024
            let head = Self.head(url, limit: limit)
            // A NUL in the first few KB is what tells a `.dat` or an extensionless binary apart from
            // source — serving it as text paints a screenful of replacement characters instead.
            if head.prefix(4096).contains(0) {
                answer("415 Unsupported Media Type", "text/plain; charset=utf-8",
                       Data("binary file (\(size) bytes) — download it to open".utf8)); return
            }
            var text = String(decoding: head, as: UTF8.self)
            if size > limit {
                text += "\n\n… truncated at \(limit / 1024) KB of \(size / 1024) KB"
                     + " — open it on the Mac for the rest\n"
            }
            // What the web editor needs to save this text back (see handleSave): which version of the
            // file it is, and whether it can be edited at all. Only a whole file can — a truncated one
            // saved back would cut it off at 512 KB — and only valid UTF-8, or the replacement
            // characters the decoding above put in would be written over the real bytes.
            var headers: [(String, String)] = []
            if Self.editable.contains(url.pathExtension.lowercased()) {
                let why = size > limit ? "large"
                    : String(data: head, encoding: .utf8) == nil ? "encoding"
                    : !FileManager.default.isWritableFile(atPath: url.path) ? "readonly" : nil
                headers.append(("X-FV-Editable", why ?? "1"))
                if why == nil { headers.append(("X-FV-Version", AuditDigest.sha256(data: head))) }
            }
            answer("200 OK", "text/plain; charset=utf-8", Data(text.utf8), headers: headers)
        }
    }

    /// What the web editor may write: notes, plans and docs. Not source — an edit to a script from a
    /// phone is one an agent should be making, with a diff and a test run behind it.
    static let editable: Set<String> = ["md", "markdown"]

    /// POST /save?path=<file>&base=<version> — a markdown file written back from the web editor.
    ///
    /// Only a file that already exists, inside a project, with an `editable` extension: this is for
    /// editing what agents and you keep in a project, not a way to put new files on the Mac (that is
    /// /upload, into a folder of its own). `base` is the version /read handed out with the text. If
    /// the file has changed since — an agent wrote to it while you were typing — the save is refused
    /// with 409 and the current version, and the page asks before `force=1` overwrites. Last writer
    /// wins silently would throw away whichever edit landed first without either side knowing.
    private func handleSave(_ conn: NWConnection, _ head: HTTPRequestHead?, _ body: Data,
                            _ query: [String: String], _ scope: WebAudit.Scope) {
        projectRoots(conn) { [weak self] roots in
            guard let self else { return }
            func answer(_ status: String, _ payload: [String: Any], facts: [String: AuditValue] = [:]) {
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
                WebAudit.shared.finish(scope, status: status, bytes: data.count, query: query,
                                       facts: facts)
                self.send(conn, status: status, type: "application/json", body: data,
                          setCookie: scope.setCookie)
            }
            guard head?.method.uppercased() == "POST" else {
                answer("405 Method Not Allowed", ["error": "POST only"]); return
            }
            guard let raw = query["path"], let target = Self.confine(raw, roots: roots) else {
                answer("403 Forbidden", ["error": "that path is not inside a project"]); return
            }
            let url = target.url
            guard Self.editable.contains(url.pathExtension.lowercased()) else {
                answer("403 Forbidden", ["error": "only markdown files can be edited here"]); return
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  let current = try? Data(contentsOf: url) else {
                answer("404 Not Found", ["error": "no such file"]); return
            }
            guard String(data: body, encoding: .utf8) != nil else {
                answer("400 Bad Request", ["error": "not UTF-8 text"]); return
            }
            let was = AuditDigest.sha256(data: current), now = AuditDigest.sha256(data: body)
            let forced = query["force"] == "1"
            let facts = AuditValue.compact(["path": .string(url.path),
                                            "file.bytes": .int(body.count),
                                            "file.bytes_before": .int(current.count),
                                            "file.sha256": .string(now),
                                            "file.sha256_before": .string(was),
                                            "file.base": query["base"].map { .string($0) },
                                            "forced": .bool(forced)])
            if !forced, query["base"] != was {
                answer("409 Conflict", ["error": "changed", "version": was], facts: facts); return
            }
            // The desktop file window's save: checked against `base` again at the moment of writing,
            // written beside the project rather than in it, swapped in with the file's mode, ACL and
            // extended attributes, and undone if an agent wrote in between (see FileSave). It replaced
            // `Data.write(.atomic)`, which left its temporary file in the project mid-write.
            // In place never: a hard link inside a project would let the LAN write its other name.
            switch FileSave.save(body, to: url.path, base: forced ? nil : was, force: forced, allowInPlace: false) {
            case .saved:
                FV.log("save: \(body.count) bytes → \(url.path)")
                answer("200 OK", ["version": now, "bytes": body.count], facts: facts)
            case .conflict(let current):
                answer("409 Conflict", ["error": "changed", "version": current ?? was], facts: facts)
            case .failed(let why):
                FV.log("save failed: \(url.path): \(why)")
                answer("500 Internal Server Error", ["error": "could not write it"], facts: facts)
            }
        }
    }

    /// GET /raw/<absolute path> — a project file as the browser itself shows it, for "open in a new
    /// tab": an HTML report rendered rather than listed as source, an image or a PDF at full size.
    ///
    /// The path is in the URL's path, not its query, so that a page's relative references resolve:
    /// `style.css` beside `report.html` is `/raw/…/style.css`, served by this same route and confined
    /// the same way. HTML and SVG come with a CSP `sandbox` that leaves out `allow-same-origin`. A
    /// file in a project is not the dashboard and must not run as it: on this origin its scripts
    /// could read /state and type into any terminal. Its own scripts still run, in an origin of
    /// their own.
    private func handleRaw(_ conn: NWConnection, _ path: String, _ query: [String: String],
                           _ scope: WebAudit.Scope) {
        let file = String(path.dropFirst("/raw".count)).removingPercentEncoding ?? ""
        projectRoots(conn) { [weak self] roots in
            guard let self else { return }
            let facts: [String: AuditValue] = ["path": .string(file)]
            func answer(_ status: String, _ type: String, _ data: Data, headers: [(String, String)] = []) {
                WebAudit.shared.finish(scope, status: status, bytes: data.count, query: query,
                                       facts: facts)
                self.send(conn, status: status, type: type, body: data, setCookie: scope.setCookie,
                          headers: [("X-Content-Type-Options", "nosniff")] + headers)
            }
            guard let target = Self.confine(file, roots: roots) else {
                answer("403 Forbidden", "text/plain; charset=utf-8",
                       Data("that path is not inside a project".utf8)); return
            }
            let url = target.url
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                answer("404 Not Found", "text/plain; charset=utf-8", Data("no such file".utf8)); return
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            guard size <= Self.maxBody else {
                answer("413 Payload Too Large", "text/plain; charset=utf-8",
                       Data("\(size / 1_048_576) MB is too large to send".utf8)); return
            }
            guard let body = try? Data(contentsOf: url) else {
                answer("500 Internal Server Error", "text/plain; charset=utf-8",
                       Data("could not read it".utf8)); return
            }
            let ext = url.pathExtension.lowercased()
            // Untyped is shown as text when it reads as text (a NUL says it does not): source,
            // configs and extensionless scripts are most of what a project holds.
            let type = Self.mimeType(forExtension: ext)
                ?? (body.prefix(4096).contains(0) ? "application/octet-stream" : "text/plain; charset=utf-8")
            var headers: [(String, String)] = []
            if ["html", "htm", "svg"].contains(ext) {
                headers.append(("Content-Security-Policy",
                                "sandbox allow-scripts allow-popups allow-forms allow-modals allow-downloads"))
            }
            if type == "application/octet-stream" {
                headers.append(("Content-Disposition",
                                "attachment; filename=\"\(Self.headerSafe(url.lastPathComponent))\""))
            }
            answer("200 OK", type, body, headers: headers)
        }
    }

    /// The first `limit` bytes of a file (empty if it can't be opened).
    static func head(_ url: URL, limit: Int) -> Data {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? fh.close() }
        return (try? fh.read(upToCount: limit)) ?? Data()
    }

    /// A filename that cannot break out of a header value — quotes and newlines would end the
    /// Content-Disposition line early and let the rest of the name become another header.
    static func headerSafe(_ s: String) -> String {
        let clean = s.filter { $0 != "\"" && $0 != "\r" && $0 != "\n" && $0 != "\\" }
        return clean.isEmpty ? "file" : clean
    }

    /// The extension out of a client-supplied filename, reduced to something that cannot escape the
    /// uploads directory or surprise a shell: letters and digits only, and short. nil if there is
    /// nothing usable left.
    static func safeExtension(_ name: String?) -> String? {
        guard let name, let dot = name.lastIndex(of: "."), dot != name.index(before: name.endIndex)
        else { return nil }
        let raw = name[name.index(after: dot)...].lowercased()
        let clean = raw.filter { $0.isLetter || $0.isNumber }
        guard !clean.isEmpty, clean.count <= 12 else { return nil }
        return String(clean)
    }

    /// Content-Type for a file we are handing back, by extension. Anything unrecognised is served as
    /// a download rather than guessed at.
    static func mimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "avif": return "image/avif"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "txt", "log", "md": return "text/plain; charset=utf-8"
        case "csv": return "text/csv; charset=utf-8"
        case "json": return "application/json"
        case "html", "htm": return "text/html; charset=utf-8"
        // What a rendered HTML page pulls in beside it, through /raw.
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "mp4", "mov": return "video/mp4"
        case "mp3": return "audio/mpeg"
        default: return nil
        }
    }

    /// The file extension for an image, from its magic bytes. nil ⇒ not an image we accept.
    static func imageExtension(_ d: Data) -> String? {
        func at(_ i: Int) -> UInt8? { i < d.count ? d[d.index(d.startIndex, offsetBy: i)] : nil }
        func matches(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            for (i, b) in bytes.enumerated() where at(offset + i) != b { return false }
            return true
        }
        func ascii(_ s: String, at offset: Int) -> Bool { matches(Array(s.utf8), at: offset) }

        if matches([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if matches([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if matches([0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if ascii("RIFF", at: 0), ascii("WEBP", at: 8) { return "webp" }
        // HEIC/HEIF: an ISO-BMFF box whose brand says so. iPhones send these unless the browser
        // transcodes, and getting the extension wrong is what stops an agent from opening it.
        if ascii("ftyp", at: 4) {
            for brand in ["heic", "heix", "heim", "heis", "hevc", "mif1", "msf1"]
            where ascii(brand, at: 8) { return "heic" }
            if ascii("avif", at: 8) { return "avif" }
        }
        return nil
    }

    private func send(_ conn: NWConnection, status: String = "200 OK", type: String, body: Data,
                      setCookie: String? = nil, disposition: String? = nil,
                      headers: [(String, String)] = []) {
        Self.write(conn, status: status, type: type, body: body, setCookie: setCookie,
                   disposition: disposition, headers: headers)
    }

    /// `send` without the instance, for replies composed off every queue this server owns.
    private static func write(_ conn: NWConnection, status: String, type: String, body: Data,
                              setCookie: String? = nil, disposition: String? = nil,
                              headers: [(String, String)] = []) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        if let disposition { head += "Content-Disposition: \(disposition)\r\n" }
        if let setCookie { head += "Set-Cookie: \(setCookie)\r\n" }   // identifies this browser's visit
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func parsePath(_ raw: String) -> (String, [String: String]) {
        guard let q = raw.firstIndex(of: "?") else { return (raw, [:]) }
        let path = String(raw[raw.startIndex..<q])
        var dict: [String: String] = [:]
        for pair in raw[raw.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let k = decodeQuery(String(kv[0]))
            let v = kv.count > 1 ? decodeQuery(String(kv[1])) : ""
            dict[k] = v
        }
        return (path, dict)
    }

    /// Decode one form-urlencoded query token: "+" is a space, then percent-decode the rest.
    private static func decodeQuery(_ s: String) -> String {
        (s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding) ?? s
    }
}
