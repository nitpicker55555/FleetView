import Foundation
import Network

/// gzip for the web server's replies, to clients that ask for it.
///
/// The dashboard is read over Tailscale from a phone, and a direct path is not a fast one: from an
/// iPhone hotspot on 2026-11-13 the pad saw 143 ms pings but 11–30 KB/s, so the 390 KB page took
/// half a minute and a conversation it had no copy of (300 KB) 26 s — while the latency badge said
/// all was well. Everything polled is JSON or the page itself, and compresses 3–4×.
///
/// Only a request carrying `Accept-Encoding: gzip` gets it: browsers and URLSession (PeerFleet) do,
/// while `project-manager` (urllib) and a plain `curl` do not and go on reading plain bodies.
enum HTTPGzip {
    /// Too small to be worth the header and the work.
    static let minBytes = 1024
    /// A big download is compressed on the server's queue before the first byte leaves; past this
    /// that wait would cost more than it saves.
    static let maxBytes = 16 * 1024 * 1024

    static func accepts(_ acceptEncoding: String?) -> Bool {
        guard let acceptEncoding else { return false }
        for item in acceptEncoding.lowercased().split(separator: ",") {
            let parts = item.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.first == "gzip" || parts.first == "*" else { continue }
            // "gzip;q=0" is a refusal, not an offer.
            let q = parts.dropFirst().first { $0.hasPrefix("q=") }.flatMap { Double($0.dropFirst(2)) }
            return (q ?? 1) > 0
        }
        return false
    }

    /// Text compresses; images, PDFs, archives and video already are.
    static func compressible(_ contentType: String) -> Bool {
        let t = contentType.lowercased()
        return t.hasPrefix("text/") || t.contains("json") || t.contains("javascript")
            || t.contains("xml") || t.contains("svg")
    }

    /// RFC 1952 around the raw DEFLATE that Foundation's `.zlib` produces (it writes no zlib header
    /// of its own — which is exactly the body a gzip member wants).
    static func gzip(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff])
        out.reserveCapacity(deflated.count + 18)
        out.append(deflated)
        var crc = crc32(data).littleEndian, size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        crcTable.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            }
        }
        return c ^ 0xFFFF_FFFF
    }
}

/// Writing a reply: what the request said it can take, a 304 for what it already has, gzip, and
/// whether the connection is kept for the next request.
///
/// Every reply goes through `write`, from every queue the server answers on, and it sees only the
/// connection — so what the request asked is noted against the connection when it is routed
/// (`note`) and taken back when the reply goes out (`take`).
enum HTTPReply {
    struct Asked {
        var gzip = false
        /// `If-None-Match`, as a list of tags with any weak prefix taken off.
        var etags: [String] = []
        /// Read the next request on this connection once the reply is sent, with whatever bytes of it
        /// have already arrived. nil: close after the reply.
        var next: ((Data) -> Void)? = nil
        var leftover = Data()

        func holds(_ tag: String) -> Bool {
            let mine = HTTPReply.bare(tag)
            return etags.contains { $0 == "*" || $0 == mine }
        }
    }

    /// Held weakly and compared by identity: a connection that is never answered must not leave
    /// what it asked to whichever one is allocated at its address next.
    private final class Box {
        weak var conn: NWConnection?
        let asked: Asked
        init(_ c: NWConnection, _ a: Asked) { conn = c; asked = a }
    }
    private static var noted: [ObjectIdentifier: Box] = [:]
    private static let lock = NSLock()

    static func note(_ conn: NWConnection, _ asked: Asked) {
        lock.lock(); defer { lock.unlock() }
        noted = noted.filter { $0.value.conn != nil }
        noted[ObjectIdentifier(conn)] = Box(conn, asked)
    }

    /// What this connection's request asked — once: the reply is the only thing that asks.
    static func take(_ conn: NWConnection) -> Asked? {
        lock.lock(); defer { lock.unlock() }
        guard let b = noted.removeValue(forKey: ObjectIdentifier(conn)), b.conn === conn else { return nil }
        return b.asked
    }

    static func etags(_ ifNoneMatch: String?) -> [String] {
        (ifNoneMatch ?? "").split(separator: ",").map { bare(String($0)) }.filter { !$0.isEmpty }
    }

    private static func bare(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("W/") { t.removeFirst(2) }
        return t
    }

    /// A strong tag for a body: FNV-1a over its bytes. Only ever compared with itself.
    static func etag(_ data: Data) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for x in b { h = (h ^ UInt64(x)) &* 0x0000_0100_0000_01b3 }
        }
        return "\"" + String(h, radix: 36) + "\""
    }

    /// How long a kept connection waits for its next request before it is closed.
    static let keepAliveSeconds = 30

    static func write(_ conn: NWConnection, status: String, type: String, body: Data,
                      setCookie: String? = nil, disposition: String? = nil,
                      headers: [(String, String)] = [], cache: String = "no-store") {
        let asked = take(conn)
        var status = status, body = body, headers = headers
        let tag = headers.first { $0.0.lowercased() == "etag" }?.1
        // The client has this already: a 304 carries the tag and no body.
        let unchanged = status.hasPrefix("200") && tag.map { asked?.holds($0) ?? false } == true
        if unchanged {
            status = "304 Not Modified"
            body = Data()
        } else if asked?.gzip == true, status.hasPrefix("200"), HTTPGzip.compressible(type),
                  (HTTPGzip.minBytes...HTTPGzip.maxBytes).contains(body.count),
                  !headers.contains(where: { $0.0.lowercased() == "content-encoding" }),
                  let packed = HTTPGzip.gzip(body), packed.count < body.count {
            body = packed
            headers += [("Content-Encoding", "gzip"), ("Vary", "Accept-Encoding")]
        }
        var head = "HTTP/1.1 \(status)\r\n"
        // A 304 says nothing about the body it stands for: a length of 0 here would be taken by a
        // cache as the new length of what it holds.
        if !unchanged {
            head += "Content-Type: \(type)\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "Cache-Control: \(cache)\r\n"
        if let disposition { head += "Content-Disposition: \(disposition)\r\n" }
        if let setCookie { head += "Set-Cookie: \(setCookie)\r\n" }   // identifies this browser's visit
        for (name, value) in headers where !(unchanged && name.lowercased() == "content-encoding") {
            head += "\(name): \(value)\r\n"
        }
        let keep = asked?.next
        head += keep == nil ? "Connection: close\r\n\r\n"
                            : "Connection: keep-alive\r\nKeep-Alive: timeout=\(keepAliveSeconds)\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        let leftover = asked?.leftover ?? Data()
        conn.send(content: out, completion: .contentProcessed { error in
            if error == nil, let keep { keep(leftover) } else { conn.cancel() }
        })
    }
}
