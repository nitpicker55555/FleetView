import FleetViewAudit
import Foundation
import Network

/// Reading requests off one connection, one after another.
///
/// Every reply used to say `Connection: close`, so each request paid a new TCP handshake and a TCP
/// slow start from nothing. With the page polling several endpoints that was over a hundred
/// connections a minute per open phone, each a round trip before the first byte — 143 ms apiece on
/// the hotspot of 2026-11-13. Now an HTTP/1.1 client that does not ask to close keeps its connection:
/// once the reply is written (HTTPReply.write) the next request is read from it, and one left idle
/// for `HTTPReply.keepAliveSeconds` is closed.
///
/// Foundation and Network only, so it is run outside the app with a stand-in router.
enum HTTPConnection {
    /// What a request header block may run to before the connection is dropped.
    static let maxHeader = 1_000_000

    typealias Route = (_ conn: NWConnection, _ header: Data, _ body: Data) -> Void

    /// Read the next request on `conn` — some of it may already be in `buffer` — note what it asked
    /// of the reply, and hand it to `route`. `idle`: this is a kept connection between requests, which
    /// is closed if nothing arrives in time.
    static func serve(_ conn: NWConnection, buffer: Data = Data(), idle: Bool = false,
                      queue: DispatchQueue, maxBody: Int, route: @escaping Route) {
        var timer: DispatchWorkItem?
        if idle, buffer.isEmpty {
            let t = DispatchWorkItem { conn.cancel() }
            queue.asyncAfter(deadline: .now() + .seconds(HTTPReply.keepAliveSeconds), execute: t)
            timer = t
        }
        readHead(conn, buffer, timer: timer, queue: queue, maxBody: maxBody, route: route)
    }

    private static let blank = Data("\r\n\r\n".utf8)

    private static func readHead(_ conn: NWConnection, _ buffer: Data, timer: DispatchWorkItem?,
                                 queue: DispatchQueue, maxBody: Int, route: @escaping Route) {
        if let end = buffer.range(of: blank) {
            timer?.cancel()
            readBody(conn, header: buffer.subdata(in: buffer.startIndex..<end.lowerBound),
                     body: buffer.subdata(in: end.upperBound..<buffer.endIndex),
                     queue: queue, maxBody: maxBody, route: route)
            return
        }
        if buffer.count > maxHeader { timer?.cancel(); conn.cancel(); return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buf = buffer
            if let data { buf.append(data) }
            // A request has begun; the rest of it is not held to the idle limit.
            if !buf.isEmpty { timer?.cancel() }
            if buf.range(of: blank) == nil, isComplete || error != nil {
                timer?.cancel(); conn.cancel(); return
            }
            readHead(conn, buf, timer: buf.isEmpty ? timer : nil, queue: queue, maxBody: maxBody, route: route)
        }
    }

    /// Headers are complete; keep reading until the declared body has arrived. Everything except an
    /// upload has no body and routes on the first pass.
    private static func readBody(_ conn: NWConnection, header: Data, body: Data,
                                 queue: DispatchQueue, maxBody: Int, route: @escaping Route) {
        let raw = String(data: header, encoding: .utf8) ?? ""
        let head = HTTPRequestHead(raw: raw)
        let expected = Int(head?.headers["content-length"] ?? "") ?? 0
        if expected > maxBody {
            HTTPReply.write(conn, status: "413 Payload Too Large", type: "text/plain", body: Data("too large".utf8))
            return
        }
        if body.count >= expected {
            let mine = body.prefix(expected), rest = body.dropFirst(expected)
            note(conn, raw: raw, head: head, leftover: Data(rest), queue: queue, maxBody: maxBody, route: route)
            route(conn, header, Data(mine))
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
            var buf = body
            if let data { buf.append(data) }
            if buf.count >= expected {
                readBody(conn, header: header, body: buf, queue: queue, maxBody: maxBody, route: route)
                return
            }
            // A client that hangs up mid-upload leaves a partial image; drop it rather than save it.
            if isComplete || error != nil { conn.cancel(); return }
            readBody(conn, header: header, body: buf, queue: queue, maxBody: maxBody, route: route)
        }
    }

    /// What the reply may be (HTTPReply.Asked): gzipped, a 304 against the tags the client holds,
    /// and on a kept connection, followed by reading the next request.
    private static func note(_ conn: NWConnection, raw: String, head: HTTPRequestHead?, leftover: Data,
                             queue: DispatchQueue, maxBody: Int, route: @escaping Route) {
        var asked = HTTPReply.Asked(gzip: HTTPGzip.accepts(head?.headers["accept-encoding"]),
                                    etags: HTTPReply.etags(head?.headers["if-none-match"]))
        // By the string: to Swift "\r\n" is one Character, so a scan for "\r" never stops.
        let line = raw.components(separatedBy: "\r\n").first ?? ""

        let closes = head?.headers["connection"].map { $0.lowercased().contains("close") } ?? false
        if line.hasSuffix("HTTP/1.1"), !closes {
            asked.leftover = leftover
            asked.next = { rest in
                serve(conn, buffer: rest, idle: true, queue: queue, maxBody: maxBody, route: route)
            }
        }
        HTTPReply.note(conn, asked)
    }
}

/// Answering once something has changed, or when the wait is up — a long poll.
///
/// The page asked every 1.5–3 s whether anything had changed, and on a quiet board the answer was
/// almost always no, each time carrying the whole answer again. Now it says what it holds (an ETag)
/// and how long it will wait; the server looks again every `every` seconds and answers the moment
/// what it would send differs, or with the unchanged answer (which the reply turns into a 304) when
/// the time is up. Idle costs nothing on the line, and a change arrives within a second.
enum LongPoll {
    /// The longest wait a request may ask for.
    static let maxWait: TimeInterval = 30

    static func run<T>(wait: TimeInterval, every: TimeInterval = 0.75, queue: DispatchQueue,
                       check: @escaping (@escaping (T, Bool) -> Void) -> Void,
                       answer: @escaping (T) -> Void) {
        let deadline = Date().addingTimeInterval(min(maxWait, max(0, wait)))
        func round() {
            check { value, changed in
                if changed || Date() >= deadline { answer(value); return }
                queue.asyncAfter(deadline: .now() + every) { round() }
            }
        }
        round()
    }
}
