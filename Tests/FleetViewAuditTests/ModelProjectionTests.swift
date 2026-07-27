import Foundation
import FleetViewAudit

/// The projection step: `Codable` model → audited fields.
///
/// This is where "a new model field is audited for free" is actually earned. If this bridge ever
/// starts dropping or mistyping values, the guarantee quietly stops holding, so it is pinned down
/// here rather than trusted.
final class ModelProjectionTests: XCTestCase {

    /// Shaped like `TerminalSession`: the same field kinds, including the ones that historically
    /// break naive encoders (UUID, optional UUID, Date, Bool next to Int).
    private struct FakeTerminal: Codable {
        var id = UUID(uuidString: "3F2A9C4E-1B77-4E0A-9C21-5D9A2C7E0B11")!
        var name = "api-refactor"
        var clusterId: UUID? = nil
        var cwd = "/Users/puzhen/PycharmProjects/FleetView"
        var autoRunClaude = true
        var subtaskDone = false
        var newTokens = 214883
        var lastActivity: Date? = nil
        var sessionId: String? = nil
    }

    func testEveryFieldIsProjected() {
        let fields = AuditValue.fields(of: FakeTerminal())
        XCTAssertEqual(fields["name"], .string("api-refactor"))
        XCTAssertEqual(fields["cwd"], .string("/Users/puzhen/PycharmProjects/FleetView"))
        XCTAssertEqual(fields["newTokens"], .int(214883))
    }

    func testBooleansDoNotBecomeIntegers() {
        // JSONSerialization hands back NSNumber for both; a naive bridge turns `true` into 1 and
        // the log starts lying about flags.
        let fields = AuditValue.fields(of: FakeTerminal())
        XCTAssertEqual(fields["autoRunClaude"], .bool(true))
        XCTAssertEqual(fields["subtaskDone"], .bool(false))
        XCTAssertNotEqual(fields["autoRunClaude"], .int(1))
    }

    func testUUIDsBecomeStrings() {
        let fields = AuditValue.fields(of: FakeTerminal())
        XCTAssertEqual(fields["id"], .string("3F2A9C4E-1B77-4E0A-9C21-5D9A2C7E0B11"))
    }

    func testNilOptionalsAreAbsentRatherThanNull() {
        let fields = AuditValue.fields(of: FakeTerminal())
        XCTAssertNil(fields["clusterId"], "an absent cluster should not appear as a field at all")
        XCTAssertNil(fields["sessionId"])
    }

    func testDroppedKeysAreExcluded() {
        // The entity id lives on the entity, not among its fields — otherwise every event would
        // carry it twice.
        let fields = AuditValue.fields(of: FakeTerminal(), dropping: ["id"])
        XCTAssertNil(fields["id"])
        XCTAssertNotNil(fields["name"])
    }

    func testANewlyAddedFieldNeedsNoRegistration() {
        // The end-to-end version of the guarantee: a model gains a property, and it is both
        // projected and turned into an event without anyone touching the audit code.
        struct GrownTerminal: Codable {
            var name = "api-refactor"
            var experimentalMode = true          // ← added "a year later"
        }
        let before = AuditSnapshot([AuditEntity(kind: "terminal", id: "t1",
                                                fields: AuditValue.fields(of: FakeTerminal()))])
        let after = AuditSnapshot([AuditEntity(kind: "terminal", id: "t1",
                                               fields: AuditValue.fields(of: GrownTerminal()))])
        let events = StateAuditor().events(for: SnapshotDiff.changes(from: before, to: after),
                                           actor: AuditActor(kind: .desktop))
        let generic = events.first { $0.name == "fleetview.terminal.changed" }
        XCTAssertNotNil(generic, "an unclassified new field must still produce an event")
        XCTAssertEqual(generic?.data["experimentalMode.to"], .bool(true))
    }

    func testNestedValuesSurvive() {
        struct Wrapper: Codable { var tags = ["a", "b"]; var counts = ["x": 1] }
        let fields = AuditValue.fields(of: Wrapper())
        XCTAssertEqual(fields["tags"], .array([.string("a"), .string("b")]))
        XCTAssertEqual(fields["counts"], .object(["x": .int(1)]))
    }

    func testNonObjectValuesProjectToNothing() {
        XCTAssertEqual(AuditValue.fields(of: [1, 2, 3]).count, 0)
    }

    func testJSONBridgeHandlesEveryScalar() {
        XCTAssertEqual(AuditValue(json: "text"), .string("text"))
        XCTAssertEqual(AuditValue(json: 7), .int(7))
        XCTAssertEqual(AuditValue(json: 1.5), .double(1.5))
        XCTAssertEqual(AuditValue(json: true), .bool(true))
        XCTAssertEqual(AuditValue(json: NSNull()), .null)
    }
}
