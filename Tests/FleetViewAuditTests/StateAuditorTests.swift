import Foundation
import FleetViewAudit

/// These tests pin down the two properties the whole design rests on:
///
/// 1. a change nobody classified is still logged (new UI and new model fields are free), and
/// 2. an operation that changes no state is still logged (the gap pure diffing leaves).
final class StateAuditorTests: XCTestCase {

    private let auditor = StateAuditor()
    private let actor = AuditActor(kind: .desktop, userName: "puzhen")

    private func terminal(_ id: String = "t1",
                          name: String = "api-refactor",
                          overrides: [String: AuditValue] = [:]) -> AuditEntity {
        var fields: [String: AuditValue] = [
            "name": .string(name),
            "status": "idle",
            "cwd": "/Users/puzhen/PycharmProjects/FleetView",
        ]
        for (k, v) in overrides { fields[k] = v }
        return AuditEntity(kind: "terminal", id: id, label: name, fields: fields,
                           context: ["project.name": "FleetView"])
    }

    private func events(from before: [AuditEntity],
                        to after: [AuditEntity],
                        intent: AuditIntent? = nil) -> [AuditEvent] {
        let changes = SnapshotDiff.changes(from: AuditSnapshot(before), to: AuditSnapshot(after))
        return auditor.events(for: changes, intent: intent, actor: actor)
    }

    // MARK: - Lifecycle

    func testCreationCapturesIdentityFields() {
        let created = terminal(overrides: ["clusterId": "c9"])
        let out = events(from: [], to: [created])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].name, "fleetview.terminal.created")
        XCTAssertEqual(out[0].types, ["creation"])
        // The spec's core ask: uuid, name, cluster and cwd all present on the creation record.
        XCTAssertEqual(out[0].target?.id, "t1")
        XCTAssertEqual(out[0].target?.name, "api-refactor")
        XCTAssertEqual(out[0].data["clusterId"], .string("c9"))
        XCTAssertEqual(out[0].data["cwd"], .string("/Users/puzhen/PycharmProjects/FleetView"))
        XCTAssertEqual(out[0].target?.fields["project.name"], .string("FleetView"))
    }

    func testRemovalIsLogged() {
        let out = events(from: [terminal()], to: [])
        XCTAssertEqual(out.map(\.name), ["fleetview.terminal.removed"])
        XCTAssertEqual(out[0].types, ["deletion"])
    }

    // MARK: - Semantic field mapping

    func testRenameBecomesItsOwnEvent() {
        let out = events(from: [terminal(name: "old")], to: [terminal(name: "new")])
        XCTAssertEqual(out.map(\.name), ["fleetview.terminal.renamed"])
        XCTAssertEqual(out[0].data["name.from"], .string("old"))
        XCTAssertEqual(out[0].data["name.to"], .string("new"))
    }

    func testStatusChangeBecomesItsOwnEvent() {
        let out = events(from: [terminal()], to: [terminal(overrides: ["status": "working"])])
        XCTAssertEqual(out.map(\.name), ["fleetview.terminal.status_changed"])
        XCTAssertEqual(out[0].data["status.from"], .string("idle"))
        XCTAssertEqual(out[0].data["status.to"], .string("working"))
    }

    func testClusterMembershipChangeBecomesItsOwnEvent() {
        let out = events(from: [terminal()], to: [terminal(overrides: ["clusterId": "c9"])])
        XCTAssertEqual(out.map(\.name), ["fleetview.terminal.cluster_changed"])
        XCTAssertEqual(out[0].data["cluster.to"], .string("c9"))
        XCTAssertNil(out[0].data["cluster.from"], "an absent previous cluster should be omitted, not null")
    }

    func testTranscriptAndSessionCollapseIntoOneEvent() {
        // Two fields, one fact ("this terminal now points at that conversation"). Emitting two
        // records for it would be the duplication the spec forbids.
        let out = events(from: [terminal()],
                         to: [terminal(overrides: ["transcriptPath": "/p/s.jsonl", "sessionId": "s"])])
        XCTAssertEqual(out.map(\.name), ["fleetview.terminal.transcript_bound"])
        XCTAssertEqual(out[0].data["transcript.to"], .string("/p/s.jsonl"))
        XCTAssertEqual(out[0].data["session.to"], .string("s"))
    }

    // MARK: - The "never silently drop" guarantee

    func testUnclassifiedFieldStillProducesAnEvent() {
        // Simulates someone adding a property to TerminalSession a year from now and not touching
        // the audit code. It must still be logged.
        let out = events(from: [terminal()], to: [terminal(overrides: ["someFutureFlag": true])])
        XCTAssertEqual(out.map(\.name), ["fleetview.terminal.changed"])
        XCTAssertEqual(out[0].data["fields"], .array([.string("someFutureFlag")]))
        XCTAssertEqual(out[0].data["someFutureFlag.to"], .bool(true))
    }

    func testUnknownEntityKindFallsBackToAGenericEvent() {
        let before = AuditSnapshot([AuditEntity(kind: "widget", id: "w1", fields: ["a": 1])])
        let after = AuditSnapshot([AuditEntity(kind: "widget", id: "w1", fields: ["a": 2])])
        let out = auditor.events(for: SnapshotDiff.changes(from: before, to: after), actor: actor)
        XCTAssertEqual(out.map(\.name), ["fleetview.widget.changed"])
    }

    func testIgnoredFieldsAreSuppressed() {
        // lastActivity/newTokens move constantly and are reported by dedicated events; logging them
        // here would be the same fact written twice at a much higher rate.
        let out = events(from: [terminal()],
                         to: [terminal(overrides: ["lastActivity": 1234, "newTokens": 99])])
        XCTAssertTrue(out.isEmpty, "expected no events, got \(out.map(\.name))")
    }

    func testIgnoredFieldDoesNotMaskARealChange() {
        let out = events(from: [terminal()],
                         to: [terminal(name: "renamed", overrides: ["lastActivity": 1234])])
        XCTAssertEqual(out.map(\.name), ["fleetview.terminal.renamed"])
    }

    // MARK: - Intent: the actions a diff cannot see

    func testOperationThatChangesNothingIsStillLogged() {
        // Raising a window reorders nothing in the model — pure diffing would lose the click
        // entirely. This is the documented gap in diff-only auditing, and the reason intents exist.
        let intent = AuditIntent("terminal.raise",
                                 event: "fleetview.terminal.raised",
                                 categories: ["process"],
                                 target: AuditTarget(kind: "terminal", id: "t1", name: "api-refactor"),
                                 data: ["origin": "card_tap"])
        let out = auditor.events(for: [], intent: intent, actor: actor)
        XCTAssertEqual(out.map(\.name), ["fleetview.terminal.raised"])
        XCTAssertEqual(out[0].data["origin"], .string("card_tap"))
        XCTAssertEqual(out[0].target?.id, "t1")
    }

    func testFailedOperationIsLoggedAsAnAlert() {
        let intent = AuditIntent("terminal.open",
                                 event: "fleetview.terminal.open_failed",
                                 outcome: .failure,
                                 message: "no live session")
        let out = auditor.events(for: [], intent: intent, actor: actor)
        XCTAssertEqual(out[0].kind, .alert)
        XCTAssertEqual(out[0].outcome, .failure)
        XCTAssertEqual(out[0].message, "no live session")
    }

    func testIntentRidesAlongOnDerivedEvents() {
        // So a status flip caused by a person is distinguishable from one a hook caused.
        let intent = AuditIntent("terminal.rename")
        let out = events(from: [terminal(name: "old")], to: [terminal(name: "new")], intent: intent)
        XCTAssertEqual(out[0].data["intent"], .string("terminal.rename"))
    }

    func testIntentDoesNotOverwriteDerivedFields() {
        let intent = AuditIntent("terminal.rename", data: ["name.from": "bogus"])
        let out = events(from: [terminal(name: "old")], to: [terminal(name: "new")], intent: intent)
        XCTAssertEqual(out[0].data["name.from"], .string("old"), "derived truth wins over declared")
    }

    // MARK: - UI selection (clicks)

    func testSelectingATerminalIsLogged() {
        // Selection is modelled as state, so a click is diffed like everything else — no view code.
        let before = AuditSnapshot([AuditEntity(kind: "ui", id: "app", fields: ["highlightedTerminal": "t1"])])
        let after = AuditSnapshot([AuditEntity(kind: "ui", id: "app", fields: ["highlightedTerminal": "t2"])])
        let out = auditor.events(for: SnapshotDiff.changes(from: before, to: after), actor: actor)
        XCTAssertEqual(out.map(\.name), ["fleetview.ui.task_selected"])
        XCTAssertEqual(out[0].data["selection.from"], .string("t1"))
        XCTAssertEqual(out[0].data["selection.to"], .string("t2"))
    }

    // MARK: - Shape

    func testActorIsAttachedToEveryEvent() {
        let out = events(from: [], to: [terminal()])
        XCTAssertEqual(out[0].resolvedActor.kind, .desktop)
        XCTAssertEqual(out[0].resolvedActor.userName, "puzhen")
    }

    func testSeveralEntitiesEachProduceTheirOwnEvents() {
        let out = events(from: [terminal("t1", name: "a")],
                         to: [terminal("t1", name: "a2"), terminal("t2", name: "b")])
        XCTAssertEqual(Set(out.map(\.name)),
                       ["fleetview.terminal.renamed", "fleetview.terminal.created"])
    }

    func testMessagesAreHumanReadable() {
        let out = events(from: [terminal()], to: [terminal(overrides: ["status": "working"])])
        XCTAssertEqual(out[0].message, #"terminal "api-refactor": status idle → working"#)
    }
}
