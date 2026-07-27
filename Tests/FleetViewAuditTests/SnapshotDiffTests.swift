import Foundation
import FleetViewAudit

final class SnapshotDiffTests: XCTestCase {

    private func terminal(_ id: String, _ fields: [String: AuditValue]) -> AuditEntity {
        AuditEntity(kind: "terminal", id: id, label: fields["name"]?.displayString, fields: fields)
    }

    func testAdditionIsDetected() {
        let before = AuditSnapshot([])
        let after = AuditSnapshot([terminal("t1", ["name": "api"])])
        let changes = SnapshotDiff.changes(from: before, to: after)
        guard case .added(let e)? = changes.first else { return XCTFail("expected an addition") }
        XCTAssertEqual(e.id, "t1")
        XCTAssertEqual(changes.count, 1)
    }

    func testRemovalIsDetected() {
        let before = AuditSnapshot([terminal("t1", ["name": "api"])])
        let changes = SnapshotDiff.changes(from: before, to: AuditSnapshot([]))
        guard case .removed(let e)? = changes.first else { return XCTFail("expected a removal") }
        XCTAssertEqual(e.id, "t1")
    }

    func testModificationReportsOnlyChangedFields() {
        let before = AuditSnapshot([terminal("t1", ["name": "api", "status": "idle", "cwd": "/x"])])
        let after = AuditSnapshot([terminal("t1", ["name": "api", "status": "working", "cwd": "/x"])])
        let changes = SnapshotDiff.changes(from: before, to: after)
        guard case .modified(_, _, let fields)? = changes.first else { return XCTFail("expected a modification") }
        XCTAssertEqual(fields.map(\.key), ["status"])
        XCTAssertEqual(fields[0].before, .string("idle"))
        XCTAssertEqual(fields[0].after, .string("working"))
    }

    func testIdenticalSnapshotsProduceNothing() {
        let snap = AuditSnapshot([terminal("t1", ["name": "api", "status": "idle"])])
        XCTAssertTrue(SnapshotDiff.changes(from: snap, to: snap).isEmpty)
    }

    func testAppearingAndDisappearingFieldsAreChanges() {
        let before = AuditSnapshot([terminal("t1", ["name": "api"])])
        let after = AuditSnapshot([terminal("t1", ["name": "api", "sessionId": "abc"])])
        let changes = SnapshotDiff.changes(from: before, to: after)
        guard case .modified(_, _, let fields)? = changes.first else { return XCTFail("expected a modification") }
        XCTAssertEqual(fields.map(\.key), ["sessionId"])
        XCTAssertNil(fields[0].before)
        XCTAssertEqual(fields[0].after, .string("abc"))
    }

    func testDifferentKindsWithTheSameIdDoNotCollide() {
        let before = AuditSnapshot([
            AuditEntity(kind: "terminal", id: "x", fields: ["a": 1]),
            AuditEntity(kind: "cluster", id: "x", fields: ["a": 1]),
        ])
        let after = AuditSnapshot([
            AuditEntity(kind: "terminal", id: "x", fields: ["a": 2]),
            AuditEntity(kind: "cluster", id: "x", fields: ["a": 1]),
        ])
        let changes = SnapshotDiff.changes(from: before, to: after)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.entity.kind, "terminal")
    }

    func testOrderingIsDeterministic() {
        // A file format must not depend on Dictionary iteration order.
        let before = AuditSnapshot([])
        let after = AuditSnapshot((1...20).map { terminal("t\($0)", ["name": .string("n\($0)")]) })
        let first = SnapshotDiff.changes(from: before, to: after).map { $0.entity.key }
        for _ in 0..<5 {
            XCTAssertEqual(SnapshotDiff.changes(from: before, to: after).map { $0.entity.key }, first)
        }
        XCTAssertEqual(first, first.sorted())
    }
}
