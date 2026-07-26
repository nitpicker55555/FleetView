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
        let cwd: String
        let transcript: String?   // agent conversation-history file (Claude/Codex), if a hook reported it
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
}

/// A tiny, dependency-free HTTP/1.1 server (Network.framework) that serves the web dashboard.
/// One page + two JSON endpoints; every request is answered once and the connection is closed.
/// All app state is read on the main actor via `AppState.webResponse`.
final class WebServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ai.eigent.fleetview.web")
    private(set) var port: Int = 0
    weak var app: AppState?

    /// Bind the first free port at/after `preferredPort` and start listening on all interfaces.
    func start(preferredPort: Int = 8080) {
        var p = preferredPort, tries = 0
        while !Tooling.isPortFree(p) && tries < 100 { p += 1; tries += 1 }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(p)) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: nwPort) else { return }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.receive(conn, buffer: Data())
        }
        l.start(queue: queue)
        listener = l
        port = p
        try? "\(p)".write(to: FV.webPortFile, atomically: true, encoding: .utf8)   // let fleetctl find us
    }

    func stop() { listener?.cancel(); listener = nil }

    // MARK: - Request handling

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {        // headers complete (GETs have no body)
                self.route(conn, header: buf.subdata(in: buf.startIndex..<end.lowerBound))
                return
            }
            if isComplete || error != nil || buf.count > 1_000_000 { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    private func route(_ conn: NWConnection, header: Data) {
        let requestLine = String(data: header, encoding: .utf8)?
            .split(separator: "\r\n").first.map(String.init) ?? ""
        let fields = requestLine.split(separator: " ")
        let rawPath = fields.count >= 2 ? String(fields[1]) : "/"
        let (path, params) = Self.parsePath(rawPath)

        if path == "/ask" { handleAsk(conn, params); return }   // long-running; handled off the main thread

        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data())
                return
            }
            MainActor.assumeIsolated {
                let (status, type, body) = app.webResponse(path: path, query: params)
                self.queue.async { self.send(conn, status: status, type: type, body: body) }
            }
        }
    }

    /// GET /ask?id=&q= — a "BTW" side query: ask the agent using its context without touching the live
    /// session. The spec lookup is quick (main actor); the agent subprocess (~10-30s) runs on a global
    /// queue so it never blocks the UI or other requests.
    private func handleAsk(_ conn: NWConnection, _ query: [String: String]) {
        guard let s = query["id"], let id = UUID(uuidString: s), let q = query["q"], !q.isEmpty else {
            send(conn, status: "400 Bad Request", type: "text/plain", body: Data("bad request".utf8)); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else {
                self?.send(conn, status: "503 Service Unavailable", type: "text/plain", body: Data()); return
            }
            let spec = MainActor.assumeIsolated { app.askSpec(id) }
            guard let spec else {
                self.send(conn, status: "409 Conflict", type: "text/plain",
                          body: Data("no agent session for this terminal yet".utf8)); return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let answer = RemoteServer.ask(spec, question: q)
                self.send(conn, type: "text/plain; charset=utf-8", body: Data(answer.utf8))
            }
        }
    }

    private func send(_ conn: NWConnection, status: String = "200 OK", type: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
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
