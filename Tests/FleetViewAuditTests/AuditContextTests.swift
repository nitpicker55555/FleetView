import Foundation
import FleetViewAudit

/// The ambient actor is what keeps `who did it` out of every call signature — and out of the view
/// layer entirely. If scoping leaks, events get attributed to the wrong person, which is worse than
/// not logging them at all.
final class AuditContextTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AuditContext.reset()
        AuditContext.fallback = AuditActor(kind: .desktop, userName: "puzhen")
    }

    override func tearDown() {
        AuditContext.reset()
        AuditContext.fallback = AuditActor(kind: .system)
        super.tearDown()
    }

    func testFallbackAppliesOutsideAnyScope() {
        // A brand-new SwiftUI button writes no logging code and still gets the right actor.
        XCTAssertEqual(AuditContext.actor.kind, .desktop)
        XCTAssertEqual(AuditContext.actor.userName, "puzhen")
    }

    func testScopeOverridesTheFallback() {
        AuditContext.with(AuditActor(kind: .web, id: "ws_1", sourceIP: "100.64.0.2")) {
            XCTAssertEqual(AuditContext.actor.kind, .web)
            XCTAssertEqual(AuditContext.actor.sourceIP, "100.64.0.2")
        }
    }

    func testScopeIsRestoredAfterwards() {
        AuditContext.with(AuditActor(kind: .web)) {}
        XCTAssertEqual(AuditContext.actor.kind, .desktop)
    }

    func testScopesNest() {
        AuditContext.with(AuditActor(kind: .web, id: "outer")) {
            AuditContext.with(AuditActor(kind: .agent, agentKind: "claude")) {
                XCTAssertEqual(AuditContext.actor.kind, .agent)
            }
            XCTAssertEqual(AuditContext.actor.kind, .web)
            XCTAssertEqual(AuditContext.actor.id, "outer")
        }
    }

    func testScopeIsRestoredWhenTheBodyThrows() {
        struct Boom: Error {}
        XCTAssertThrowsError(try AuditContext.with(AuditActor(kind: .cli)) { throw Boom() })
        XCTAssertEqual(AuditContext.actor.kind, .desktop, "a thrown error must not leak the frame")
    }

    func testTraceIsInheritedByInnerScopes() {
        AuditContext.with(AuditActor(kind: .web), trace: AuditTrace(id: "tr_1", requestID: "rq_1")) {
            AuditContext.with(AuditActor(kind: .agent)) {
                XCTAssertEqual(AuditContext.trace?.id, "tr_1", "correlation must survive a nested scope")
            }
        }
    }

    func testScopeReturnsTheBodysValue() {
        let n = AuditContext.with(AuditActor(kind: .cli)) { 42 }
        XCTAssertEqual(n, 42)
    }

    func testContextIsPerThread() {
        // One thread's actor must never bleed into another's — the web server handles requests off
        // the main thread before hopping onto it.
        let done = DispatchSemaphore(value: 0)
        var observed: String?
        AuditContext.with(AuditActor(kind: .web, id: "main-scope")) {
            DispatchQueue.global().async {
                observed = AuditContext.actor.id
                done.signal()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        }
        XCTAssertNotEqual(observed, "main-scope", "a scope must not leak across threads")
    }

    func testAuditorStampsTheAmbientActorOntoEmittedEvents() {
        let sink = MemoryAuditSink()
        let auditor = Auditor(sink: sink)
        AuditContext.with(AuditActor(kind: .web, id: "ws_9", sourceIP: "10.0.0.5")) {
            auditor.emit("fleetview.web.action", message: "did a thing")
        }
        XCTAssertEqual(sink.events.first?.resolvedActor.kind, .web)
        XCTAssertEqual(sink.events.first?.resolvedActor.sourceIP, "10.0.0.5")
    }

    func testExplicitActorOnAnEventWins() {
        let sink = MemoryAuditSink()
        let auditor = Auditor(sink: sink)
        AuditContext.with(AuditActor(kind: .web)) {
            auditor.emit(AuditEvent(name: "fleetview.shell.command_started",
                                    actor: AuditActor(kind: .shell)))
        }
        XCTAssertEqual(sink.events.first?.resolvedActor.kind, .shell)
    }
}
