import FleetViewAudit
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
    let askGeo: Bool              // whether the page should ask the device for its position
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

        if path == "/ask" { handleAsk(conn, params, scope); return }   // long-running; off the main thread
        if path == "/upload" {                                         // writes a file; no app state
            handleUpload(conn, request, body, params, scope); return
        }

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
        func answer(_ status: String, _ type: String, _ data: Data) {
            WebAudit.shared.finish(scope, status: status, bytes: data.count, query: query)
            send(conn, status: status, type: type, body: data, setCookie: scope.setCookie)
        }
        guard head?.method.uppercased() == "POST" else {
            answer("405 Method Not Allowed", "text/plain", Data("POST only".utf8)); return
        }
        guard !body.isEmpty else {
            answer("400 Bad Request", "application/json", Data(#"{"error":"empty body"}"#.utf8)); return
        }
        guard let ext = Self.imageExtension(body) else {
            answer("415 Unsupported Media Type", "application/json",
                   Data(#"{"error":"not an image"}"#.utf8)); return
        }
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
        answer("200 OK", "application/json", data)
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
                      setCookie: String? = nil) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        if let setCookie { head += "Set-Cookie: \(setCookie)\r\n" }   // identifies this browser's visit
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
