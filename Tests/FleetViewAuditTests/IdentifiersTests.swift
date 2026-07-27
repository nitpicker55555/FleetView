import Foundation
import FleetViewAudit

final class IdentifiersTests: XCTestCase {

    // MARK: - ULID (event ids)

    func testULIDIsCanonicalLength() {
        XCTAssertEqual(Identifiers.ulid().count, 26)
    }

    func testULIDUsesCrockfordAlphabetOnly() {
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        XCTAssertTrue(Identifiers.ulid().allSatisfy { allowed.contains($0) })
    }

    func testULIDsSortByTime() {
        let early = Identifiers.ulid(now: Date(timeIntervalSince1970: 1_000_000))
        let later = Identifiers.ulid(now: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertLessThan(early, later, "ULIDs must sort lexicographically by time")
    }

    func testULIDsInSameMillisecondStayOrdered() {
        // Ordering within a tick is the whole reason for the monotonic counter: two events in the
        // same millisecond still have to be replayable in the order they happened.
        let now = Date(timeIntervalSince1970: 1_700_000_000.123)
        let ids = (0..<200).map { _ in Identifiers.ulid(now: now) }
        XCTAssertEqual(ids, ids.sorted())
        XCTAssertEqual(Set(ids).count, ids.count, "same-millisecond ids must still be unique")
    }

    // MARK: - UUIDv7 (panel version ids)

    func testUUIDv7HasUUIDShape() {
        let id = Identifiers.uuidV7()
        XCTAssertNotNil(UUID(uuidString: id), "must still be a parseable UUID: \(id)")
        XCTAssertEqual(id.count, 36)
    }

    func testUUIDv7SetsVersionAndVariantNibbles() {
        let id = Identifiers.uuidV7()
        let parts = id.split(separator: "-")
        XCTAssertEqual(parts[2].first, "7", "version nibble must be 7 (RFC 9562)")
        XCTAssertTrue("89ab".contains(parts[3].first!), "variant nibble must be 10xx")
    }

    func testUUIDv7SortsChronologicallyAsPlainStrings() {
        // This is why panel versions use v7: the newest archived panel is the lexicographically
        // largest filename, so `ls` alone finds it — no index, no mtime.
        let early = Identifiers.uuidV7(now: Date(timeIntervalSince1970: 1_700_000_000))
        let later = Identifiers.uuidV7(now: Date(timeIntervalSince1970: 1_700_000_060))
        XCTAssertLessThan(early, later)
    }

    func testUUIDv7EncodesTheTimestampInTheFirst48Bits() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let id = Identifiers.uuidV7(now: when)
        let hex = id.replacingOccurrences(of: "-", with: "").prefix(12)
        let millis = UInt64(hex, radix: 16)
        XCTAssertEqual(millis, UInt64(when.timeIntervalSince1970 * 1000))
    }

    func testUUIDv7SameMillisecondIdsAreUniqueAndOrdered() {
        let now = Date(timeIntervalSince1970: 1_700_000_000.5)
        let ids = (0..<100).map { _ in Identifiers.uuidV7(now: now) }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, ids.sorted())
    }
}
