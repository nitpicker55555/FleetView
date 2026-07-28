import Foundation
import FleetViewAudit

/// End-to-end: a realistic session written to a real file, then read back and checked as a whole.
///
/// The unit tests pin down each rule; this one checks that the rules compose into a log a person
/// can actually read — right actors, right order, no duplicates, nothing leaked.
final class IntegrationTests: XCTestCase {

    private var directory: URL!
    private var auditor: Auditor!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fv-audit-integration-\(UUID().uuidString)")
        auditor = Auditor(sink: FileAuditSink(directory: directory,
                                              resource: AuditResource(serviceVersion: "1.4.2",
                                                                      instanceID: "7f3a1c9e")))
        AuditContext.reset()
        AuditContext.fallback = AuditActor(kind: .desktop, userName: "puzhen")
    }

    override func tearDown() {
        AuditContext.reset()
        AuditContext.fallback = AuditActor(kind: .system)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func terminal(_ name: String, status: String, cluster: String? = nil) -> AuditEntity {
        AuditEntity(kind: "terminal", id: "3F2A9C4E", label: name,
                    fields: AuditValue.compact([
                        "name": .string(name),
                        "status": .string(status),
                        "cwd": .string("/Users/puzhen/PycharmProjects/FleetView"),
                        "clusterId": cluster.map { .string($0) },
                    ]),
                    context: ["project.name": "FleetView"])
    }

    /// Read the log back as parsed JSON objects.
    private func lines() throws -> [[String: Any]] {
        auditor.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let name = try XCTUnwrap(files.first { $0.hasSuffix(".jsonl") })
        let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// Replays roughly the day the spec describes.
    private func runSession() {
        var snapshot = AuditSnapshot([])

        auditor.emit("fleetview.app.started", categories: ["configuration"],
                     message: "FleetView 1.4.2 started")

        // 1. Someone creates a terminal at the Mac. No actor is passed anywhere.
        let created = AuditSnapshot([terminal("api-refactor", status: "shell", cluster: "9B1D")])
        auditor.record(from: snapshot, to: created, intent: AuditIntent("terminal.create"))
        snapshot = created

        // 2. The agent's hooks report a session and a prompt.
        let agent = AuditActor(kind: .agent, id: "24fc7a41", name: "api-refactor", agentKind: "claude")
        AuditContext.with(agent) {
            auditor.emit("fleetview.agent.session_started", categories: ["session"],
                         data: ["transcript.path": .string("/Users/puzhen/.claude/projects/x/24fc7a41.jsonl")])
            auditor.emit("fleetview.agent.prompt_submitted", categories: ["session"],
                         data: ["prompt.chars": .int(142),
                                "prompt.sha256": .string(AuditDigest.short("do the thing")),
                                "transcript.path": .string("/Users/puzhen/.claude/projects/x/24fc7a41.jsonl")])
            let working = AuditSnapshot([terminal("api-refactor", status: "working", cluster: "9B1D")])
            auditor.record(from: snapshot, to: working)
            snapshot = working
        }

        // 3. A command runs at the shell prompt, with a credential in it.
        let shell = AuditActor(kind: .shell, name: "api-refactor", userName: "puzhen")
        AuditContext.with(shell) {
            let redaction = Redaction()
            let raw = "TOKEN=ghp_supersecretvalue swift build -c release"
            let clean = redaction.apply(to: raw)
            auditor.emit(AuditEvent(name: "fleetview.shell.command_started",
                                    categories: ["process"], types: ["start"],
                                    data: ["cmd.id": .string("c1"),
                                           "cmd.line": .string(clean.text),
                                           "cmd.redacted": .bool(clean.redacted)]))
            auditor.emit(AuditEvent(name: "fleetview.shell.command_finished",
                                    categories: ["process"], types: ["end"],
                                    outcome: .success,
                                    data: ["cmd.id": .string("c1"), "cmd.exit_code": .int(0)]))
        }

        // 4. A phone joins over Tailscale and renames the terminal.
        let phone = AuditActor(kind: .web, id: "ws_1", name: "iPhone · Safari",
                               sourceIP: "100.101.7.23", sourcePort: 51544,
                               userAgent: "Mozilla/5.0 (iPhone) Safari",
                               geo: ["client.geo.city_name": "Munich",
                                     "fleetview.web.scope": "tailscale"])
        AuditContext.with(phone, trace: AuditTrace(id: "tr_1", requestID: "rq_1", webSessionID: "ws_1")) {
            auditor.emit("fleetview.web.session_started", categories: ["authentication", "web"])
            auditor.emit("fleetview.web.terminal_attached", categories: ["session"])
            // The rename itself is logged by the diff, with no logging code in the handler.
            let renamed = AuditSnapshot([terminal("api-v2", status: "working", cluster: "9B1D")])
            auditor.record(from: snapshot, to: renamed, intent: AuditIntent("web.action",
                                                                            data: ["do": "rename"]))
            snapshot = renamed
            // And an action that changes nothing still leaves a trace.
            auditor.record(from: snapshot, to: snapshot,
                           intent: AuditIntent("terminal.raise", event: "fleetview.terminal.raised"))
        }

        // 5. An agent writes a panel; the archive records which conversation produced it.
        let version = PanelVersion(uuid: Identifiers.uuidV7(), sha256: "3b1f", bytes: 7412,
                                   title: "CI 构建监控", previous: nil,
                                   attribution: PanelAttribution(method: .hookToolMatch,
                                                                 terminalID: "3F2A9C4E",
                                                                 terminalName: "api-v2",
                                                                 agentKind: "claude",
                                                                 sessionID: "24fc7a41",
                                                                 transcriptPath: "/p/24fc7a41.jsonl",
                                                                 tool: "Write"),
                                   timestamp: Date())
        auditor.emit(AuditEvent(name: "fleetview.panel.version_created",
                                categories: ["configuration"], types: ["creation"],
                                actor: agent, data: version.auditData))
    }

    // MARK: - Assertions over the whole log

    func testTheWholeNarrativeIsRecorded() throws {
        runSession()
        let names = try lines().compactMap { $0["event.name"] as? String }
        for expected in ["fleetview.log.opened",
                         "fleetview.app.started",
                         "fleetview.terminal.created",
                         "fleetview.agent.session_started",
                         "fleetview.agent.prompt_submitted",
                         "fleetview.terminal.status_changed",
                         "fleetview.shell.command_started",
                         "fleetview.shell.command_finished",
                         "fleetview.web.session_started",
                         "fleetview.web.terminal_attached",
                         "fleetview.terminal.renamed",
                         "fleetview.terminal.raised",
                         "fleetview.panel.version_created"] {
            XCTAssertTrue(names.contains(expected), "missing \(expected) in \(names)")
        }
    }

    func testEveryLineIsOneRecordUnderTheAtomicLimit() throws {
        runSession()
        auditor.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let name = try XCTUnwrap(files.first { $0.hasSuffix(".jsonl") })
        let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        for line in text.split(separator: "\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, AuditEncoder.maxLineBytes)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }

    func testEachEventIsAttributedToWhoeverCausedIt() throws {
        runSession()
        let byName = Dictionary(try lines().compactMap { line -> (String, [String: Any])? in
            guard let name = line["event.name"] as? String else { return nil }
            return (name, line)
        }, uniquingKeysWith: { a, _ in a })

        func actorKind(_ event: String) -> String? {
            ((byName[event]?["fleetview.actor"]) as? [String: Any])?["type"] as? String
        }
        XCTAssertEqual(actorKind("fleetview.terminal.created"), "desktop")
        XCTAssertEqual(actorKind("fleetview.agent.prompt_submitted"), "agent")
        XCTAssertEqual(actorKind("fleetview.shell.command_started"), "shell")
        // The rename went through no logging code of its own — the ambient context supplied this.
        XCTAssertEqual(actorKind("fleetview.terminal.renamed"), "web")
        XCTAssertEqual(byName["fleetview.terminal.renamed"]?["source.ip"] as? String, "100.101.7.23")
        XCTAssertEqual(byName["fleetview.terminal.renamed"]?["client.geo.city_name"] as? String, "Munich")
    }

    func testTheLogNeverContainsASecret() throws {
        runSession()
        auditor.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let name = try XCTUnwrap(files.first { $0.hasSuffix(".jsonl") })
        let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        XCTAssertFalse(text.contains("ghp_supersecretvalue"), "a credential reached the log")
        XCTAssertTrue(text.contains("cmd.redacted"), "and the redaction was declared")
    }

    func testConversationContentIsReferencedNeverCopied() throws {
        runSession()
        let prompt = try XCTUnwrap(try lines().first { ($0["event.name"] as? String) == "fleetview.agent.prompt_submitted" })
        let data = try XCTUnwrap(prompt["fleetview.data"] as? [String: Any])
        XCTAssertNotNil(data["transcript.path"], "the pointer to the real content must be present")
        XCTAssertNotNil(data["prompt.sha256"])
        XCTAssertEqual(data["prompt.chars"] as? Int, 142)
    }

    func testPanelVersionSaysWhichConversationProducedIt() throws {
        runSession()
        let panel = try XCTUnwrap(try lines().first { ($0["event.name"] as? String) == "fleetview.panel.version_created" })
        let data = try XCTUnwrap(panel["fleetview.data"] as? [String: Any])
        XCTAssertEqual(data["agent.session.id"] as? String, "24fc7a41")
        XCTAssertEqual(data["transcript.path"] as? String, "/p/24fc7a41.jsonl")
        XCTAssertEqual(data["attribution.method"] as? String, "hook_tool_match")
        XCTAssertNotNil(data["panel.uuid"])
        XCTAssertNotNil(panel["@timestamp"], "when it was produced")
    }

    func testSequenceNumbersHaveNoGaps() throws {
        runSession()
        let sequences = try lines().compactMap { $0["event.sequence"] as? Int }
        XCTAssertEqual(sequences, Array(1...sequences.count), "a gap means lines were dropped")
    }

    func testEventIdsSortInWrittenOrder() throws {
        runSession()
        let ids = try lines().compactMap { $0["event.id"] as? String }
        XCTAssertEqual(ids, ids.sorted(), "ULIDs must reconstruct the order events happened in")
    }

    func testAReaderCanFollowOneRequestEndToEnd() throws {
        runSession()
        let traced = try lines().filter {
            (($0["fleetview.trace"] as? [String: Any])?["id"] as? String) == "tr_1"
        }
        // Session start, attach, the rename it caused, and the raise that changed nothing.
        XCTAssertGreaterThanOrEqual(traced.count, 4)
    }
}
