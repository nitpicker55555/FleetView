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
        let running: Int          // seconds the current run has been going, -1 if it isn't running
        let lastRun: Int          // seconds the last finished run took, -1 if it has never run
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
        if path == "/files" { handleFileList(conn, params, scope); return }
        if path == "/file" { handleFileGet(conn, params, scope); return }
        if path == "/browse" { handleBrowse(conn, params, scope); return }
        if path == "/read" { handleRead(conn, params, scope); return }

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
        answer("200 OK", "application/json", data)
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
        func answer(_ status: String, _ type: String, _ data: Data, disposition: String? = nil) {
            WebAudit.shared.finish(scope, status: status, bytes: data.count, query: query)
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
               disposition: "\(inline ? "inline" : "attachment"); filename=\"\(Self.headerSafe(name))\"")
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
            func answer(_ status: String, _ data: Data) {
                WebAudit.shared.finish(scope, status: status, bytes: data.count, query: query)
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
            answer("200 OK", Self.listing(target.url, root: target.root))
        }
    }

    /// One directory as JSON: directories first, then files, each with what the row shows.
    ///
    /// Capped, because a project contains `node_modules` and a phone does not want ninety thousand
    /// rows — and the cap is reported rather than silently applied, so a short list can be trusted
    /// to be the whole list. The names are sorted before the cap so which 3000 you get is stable.
    static func listing(_ dir: URL, root: URL) -> Data {
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
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    /// GET /read?path=<file> — the bytes of one file inside a project.
    ///
    /// Source is what this is for, so anything without a binary type of its own comes back as UTF-8
    /// text. Images and PDFs keep their own type and the page just shows them; a file that turns out
    /// to be binary is refused with its size, and `?dl=1` fetches it as a download instead.
    private func handleRead(_ conn: NWConnection, _ query: [String: String], _ scope: WebAudit.Scope) {
        projectRoots(conn) { [weak self] roots in
            guard let self else { return }
            func answer(_ status: String, _ type: String, _ data: Data, disposition: String? = nil) {
                WebAudit.shared.finish(scope, status: status, bytes: data.count, query: query)
                self.send(conn, status: status, type: type, body: data, setCookie: scope.setCookie,
                          disposition: disposition)
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
            answer("200 OK", "text/plain; charset=utf-8", Data(text.utf8))
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
                      setCookie: String? = nil, disposition: String? = nil) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        if let disposition { head += "Content-Disposition: \(disposition)\r\n" }
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
