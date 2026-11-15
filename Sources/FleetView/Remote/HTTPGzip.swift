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

    // MARK: - Which connection asked for it

    /// Replies are written by a static `write` that sees only the connection, from every queue the
    /// server answers on, so the request's answer is noted against the connection when it is routed
    /// and taken back when the reply goes out. Held weakly and compared by identity: a connection
    /// that is never answered must not leave its "yes" to whichever one is allocated at its address
    /// next.
    private final class Weak { weak var conn: NWConnection?; init(_ c: NWConnection) { conn = c } }
    private static var asked: [ObjectIdentifier: Weak] = [:]
    private static let lock = NSLock()

    static func note(_ conn: NWConnection, acceptEncoding: String?) {
        guard accepts(acceptEncoding) else { return }
        lock.lock(); defer { lock.unlock() }
        asked = asked.filter { $0.value.conn != nil }
        asked[ObjectIdentifier(conn)] = Weak(conn)
    }

    /// Whether this connection's request takes gzip — once: the reply is the only thing that asks.
    static func take(_ conn: NWConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let w = asked.removeValue(forKey: ObjectIdentifier(conn)) else { return false }
        return w.conn === conn
    }
}
