import Foundation
import FleetViewAudit

final class EnvelopeAndSinkTests: XCTestCase {

    private func encoder() -> AuditEncoder {
        AuditEncoder(resource: AuditResource(serviceVersion: "1.4.2", hostName: "test-host",
                                             osVersion: "15.3.0", pid: 4711, instanceID: "7f3a1c9e"),
                     formatter: TimestampFormatter(timeZone: TimeZone(identifier: "UTC")!))
    }

    private func parse(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    // MARK: - Wire format

    func testLineIsSingleLineValidJSON() throws {
        let line = encoder().line(for: AuditEvent(name: "fleetview.terminal.created",
                                                  message: "multi\nline\tmessage"))
        XCTAssertFalse(line.contains("\n"))
        _ = try parse(line)
    }

    func testEnvelopeCarriesTheECSAndResourceFields() throws {
        let event = AuditEvent(name: "fleetview.terminal.created",
                               categories: ["process"], types: ["creation"],
                               message: "created",
                               actor: AuditActor(kind: .desktop, userName: "puzhen"),
                               target: AuditTarget(kind: "terminal", id: "t1", name: "api"))
        let json = try parse(encoder().line(for: event))
        XCTAssertEqual(json["event.name"] as? String, "fleetview.terminal.created")
        XCTAssertEqual(json["event.kind"] as? String, "event")
        XCTAssertEqual(json["event.category"] as? [String], ["process"])
        XCTAssertEqual(json["event.type"] as? [String], ["creation"])
        XCTAssertEqual(json["event.outcome"] as? String, "success")
        XCTAssertEqual(json["event.dataset"] as? String, "fleetview.audit")
        XCTAssertEqual(json["message"] as? String, "created")
        XCTAssertEqual(json["service.version"] as? String, "1.4.2")
        XCTAssertEqual(json["host.name"] as? String, "test-host")
        XCTAssertEqual(json["process.pid"] as? Int, 4711)
        XCTAssertEqual(json["fleetview.instance.id"] as? String, "7f3a1c9e")
        XCTAssertEqual(json["fleetview.schema"] as? Int, 1)
        XCTAssertNotNil(json["ecs.version"])
    }

    func testTargetKeepsBothIdAndName() throws {
        let event = AuditEvent(name: "fleetview.terminal.renamed",
                               target: AuditTarget(kind: "terminal", id: "3F2A", name: "api-refactor",
                                                   fields: ["cluster.name": "swarm"]))
        let json = try parse(encoder().line(for: event))
        let target = try XCTUnwrap(json["fleetview.target"] as? [String: Any])
        XCTAssertEqual(target["kind"] as? String, "terminal")
        XCTAssertEqual(target["terminal.id"] as? String, "3F2A")
        XCTAssertEqual(target["terminal.name"] as? String, "api-refactor")
        XCTAssertEqual(target["cluster.name"] as? String, "swarm")
    }

    func testNetworkActorFieldsArePromotedToECSTopLevel() throws {
        // So an off-the-shelf collector (Filebeat, Vector) understands them with no transform.
        let actor = AuditActor(kind: .web, sourceIP: "100.101.7.23", sourcePort: 51544,
                               userAgent: "Mozilla/5.0",
                               geo: ["client.geo.city_name": "Munich"])
        let json = try parse(encoder().line(for: AuditEvent(name: "fleetview.web.session_started", actor: actor)))
        XCTAssertEqual(json["source.ip"] as? String, "100.101.7.23")
        XCTAssertEqual(json["source.port"] as? Int, 51544)
        XCTAssertEqual(json["user_agent.original"] as? String, "Mozilla/5.0")
        XCTAssertEqual(json["client.geo.city_name"] as? String, "Munich")
    }

    func testDesktopEventsCarryNoNetworkFields() throws {
        let json = try parse(encoder().line(for: AuditEvent(name: "fleetview.terminal.raised",
                                                            actor: AuditActor(kind: .desktop))))
        XCTAssertNil(json["source.ip"])
        XCTAssertNil(json["user_agent.original"])
    }

    func testSequenceIncrementsMonotonically() throws {
        let enc = encoder()
        let a = try parse(enc.line(for: AuditEvent(name: "a")))
        let b = try parse(enc.line(for: AuditEvent(name: "b")))
        XCTAssertEqual((b["event.sequence"] as? Int) ?? 0, ((a["event.sequence"] as? Int) ?? 0) + 1)
    }

    func testTimestampCarriesAnOffsetAndMilliseconds() throws {
        let json = try parse(encoder().line(for: AuditEvent(name: "a", timestamp: Date(timeIntervalSince1970: 0))))
        XCTAssertEqual(json["@timestamp"] as? String, "1970-01-01T00:00:00.000Z")
    }

    func testEmptySectionsAreOmittedRatherThanNull() throws {
        let json = try parse(encoder().line(for: AuditEvent(name: "a")))
        XCTAssertNil(json["fleetview.target"])
        XCTAssertNil(json["fleetview.trace"])
        XCTAssertNil(json["fleetview.data"])
        XCTAssertNil(json["message"])
    }

    // MARK: - Line size (atomic append depends on it)

    func testOversizedEventIsTruncatedBelowTheAtomicWriteLimit() throws {
        let huge = String(repeating: "x", count: 200_000)
        let event = AuditEvent(name: "fleetview.agent.prompt_submitted",
                               message: huge,
                               target: AuditTarget(kind: "terminal", id: "t1", name: "api"),
                               data: ["prompt.preview": .string(huge), "prompt.chars": 200_000])
        let line = encoder().line(for: event)
        XCTAssertLessThanOrEqual(line.utf8.count, AuditEncoder.maxLineBytes,
                                 "lines over PIPE_BUF break atomic appends between two instances")
        let json = try parse(line)
        // Identity survives; only content is sacrificed.
        XCTAssertEqual(json["event.name"] as? String, "fleetview.agent.prompt_submitted")
        let target = try XCTUnwrap(json["fleetview.target"] as? [String: Any])
        XCTAssertEqual(target["terminal.name"] as? String, "api")
        let data = try XCTUnwrap(json["fleetview.data"] as? [String: Any])
        XCTAssertEqual(data["_truncated"] as? Bool, true)
        XCTAssertEqual(data["prompt.chars"] as? Int, 200_000, "scalars must not be lost to truncation")
    }

    func testNormalEventsAreNotTruncated() throws {
        let event = AuditEvent(name: "fleetview.terminal.created",
                               message: #"terminal "api-refactor" created"#,
                               data: ["cwd": "/Users/puzhen/PycharmProjects/FleetView"])
        let json = try parse(encoder().line(for: event))
        let data = try XCTUnwrap(json["fleetview.data"] as? [String: Any])
        XCTAssertNil(data["_truncated"])
    }

    // MARK: - File sink

    func testFileSinkWritesHeaderThenEvents() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fv-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sink = FileAuditSink(directory: dir, resource: AuditResource(instanceID: "test"))
        sink.write(AuditEvent(name: "fleetview.terminal.created"))
        sink.write(AuditEvent(name: "fleetview.terminal.removed"))
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let logName = try XCTUnwrap(files.first { $0.hasPrefix("audit-") && $0.hasSuffix(".jsonl") })
        let text = try String(contentsOf: dir.appendingPathComponent(logName), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 3, "a header plus two events")
        let header = try parse(lines[0])
        XCTAssertEqual(header["event.name"] as? String, "fleetview.log.opened")
        XCTAssertEqual(try parse(lines[1])["event.name"] as? String, "fleetview.terminal.created")
        XCTAssertEqual(try parse(lines[2])["event.name"] as? String, "fleetview.terminal.removed")
    }

    func testFileSinkAppendsRatherThanOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fv-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = FileAuditSink(directory: dir, resource: AuditResource(instanceID: "a"))
        first.write(AuditEvent(name: "fleetview.app.started"))
        first.flush()

        // A second instance — the scenario where two FleetViews share one log file.
        let second = FileAuditSink(directory: dir, resource: AuditResource(instanceID: "b"))
        second.write(AuditEvent(name: "fleetview.app.started"))
        second.flush()

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let logName = try XCTUnwrap(files.first { $0.hasSuffix(".jsonl") })
        let text = try String(contentsOf: dir.appendingPathComponent(logName), encoding: .utf8)
        let instances = text.split(separator: "\n").compactMap { line -> String? in
            (try? parse(String(line)))?["fleetview.instance.id"] as? String
        }
        XCTAssertTrue(instances.contains("a") && instances.contains("b"),
                      "both instances must survive in one file")
    }

    func testFileSinkCreatesPrivateFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fv-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sink = FileAuditSink(directory: dir, resource: AuditResource())
        sink.write(AuditEvent(name: "fleetview.app.started"))
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let logPath = dir.appendingPathComponent(try XCTUnwrap(files.first)).path
        let perms = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: logPath)[.posixPermissions] as? NSNumber)
        // The log holds IP addresses, command lines and working directories.
        XCTAssertEqual(perms.int16Value & 0o077, 0, "must not be group/world readable")
    }

    func testDisabledAuditorWritesNothing() {
        let sink = MemoryAuditSink()
        let auditor = Auditor(sink: sink, isEnabled: false)
        auditor.emit("fleetview.terminal.created")
        auditor.record(from: AuditSnapshot([]),
                       to: AuditSnapshot([AuditEntity(kind: "terminal", id: "t1")]))
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testFailureHelperProducesAnAlert() {
        let sink = MemoryAuditSink()
        Auditor(sink: sink).failure("fleetview.web.request_denied", reason: "unknown terminal")
        XCTAssertEqual(sink.events.first?.kind, .alert)
        XCTAssertEqual(sink.events.first?.outcome, .failure)
        XCTAssertEqual(sink.events.first?.data["reason"], .string("unknown terminal"))
    }
}
