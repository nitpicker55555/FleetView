import Foundation

/// Time-ordered identifiers.
///
/// Both generators here are monotonic *within a millisecond* so that two events produced in the
/// same tick still sort in the order they happened — the audit log's whole value depends on being
/// able to reconstruct a sequence, and wall-clock timestamps alone are too coarse.
public enum Identifiers {
    private static let lock = NSLock()
    private static var lastULIDMillis: UInt64 = 0
    private static var lastULIDRandom: [UInt8] = []
    private static var lastUUIDMillis: UInt64 = 0
    private static var lastUUIDCounter: UInt16 = 0

    // MARK: - ULID (event ids)

    private static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// A ULID: 48-bit millisecond timestamp + 80 bits of randomness, Crockford base32, 26 chars.
    /// Sorts lexicographically by time, which is why the log can be ordered by `event.id` alone.
    public static func ulid(now: Date = Date()) -> String {
        let millis = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        lock.lock()
        var random: [UInt8]
        if millis == lastULIDMillis, !lastULIDRandom.isEmpty {
            random = increment(lastULIDRandom)   // same millisecond → keep strict ordering
        } else {
            random = (0..<10).map { _ in UInt8.random(in: 0...255) }
        }
        lastULIDMillis = millis
        lastULIDRandom = random
        lock.unlock()

        var bits: [UInt8] = []
        for shift in stride(from: 40, through: 0, by: -8) { bits.append(UInt8((millis >> UInt64(shift)) & 0xFF)) }
        bits.append(contentsOf: random)
        return base32(bits)
    }

    /// Big-endian +1 with carry; on overflow we simply wrap (a 2^80 collision inside one
    /// millisecond is not a real scenario).
    private static func increment(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        var i = out.count - 1
        while i >= 0 {
            if out[i] == 0xFF { out[i] = 0; i -= 1 } else { out[i] += 1; break }
        }
        return out
    }

    /// 16 bytes → 26 Crockford base32 chars (128 bits, left-padded to 130 so it divides by 5).
    private static func base32(_ bytes: [UInt8]) -> String {
        var buffer: UInt64 = 0
        var bits = 2            // the two pad bits ULID puts at the front
        var out = ""
        for byte in bytes {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                out.append(crockford[Int((buffer >> UInt64(bits - 5)) & 0x1F)])
                bits -= 5
            }
            buffer &= (1 << UInt64(bits)) - 1   // keep only the undrained tail
        }
        return out
    }

    // MARK: - UUIDv7 (panel version ids)

    /// A UUID version 7 (RFC 9562): the first 48 bits are the Unix millisecond timestamp, so these
    /// sort chronologically as plain strings. That is exactly why panel versions use it — the newest
    /// archived panel is simply the lexicographically largest filename, recoverable with `ls` alone,
    /// no index and no mtime needed.
    public static func uuidV7(now: Date = Date()) -> String {
        let millis = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        lock.lock()
        if millis == lastUUIDMillis {
            lastUUIDCounter &+= 1
        } else {
            lastUUIDMillis = millis
            lastUUIDCounter = 0
        }
        let counter = lastUUIDCounter
        lock.unlock()

        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8((millis >> UInt64(8 * (5 - i))) & 0xFF) }
        // rand_a (12 bits) carries a per-millisecond counter so same-tick ids stay ordered.
        bytes[6] = 0x70 | UInt8((counter >> 8) & 0x0F)          // version 7
        bytes[7] = UInt8(counter & 0xFF)
        for i in 8..<16 { bytes[i] = UInt8.random(in: 0...255) }
        bytes[8] = (bytes[8] & 0x3F) | 0x80                     // variant 10xx

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let s = Array(hex)
        func part(_ range: Range<Int>) -> String { String(s[range]) }
        return part(0..<8) + "-" + part(8..<12) + "-" + part(12..<16) + "-"
             + part(16..<20) + "-" + part(20..<32)
    }

    /// A short random tag for the process instance (two FleetViews can share one log file).
    public static func shortRandom() -> String {
        (0..<8).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
    }
}
