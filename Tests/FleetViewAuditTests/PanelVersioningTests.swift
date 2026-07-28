import Foundation
import FleetViewAudit

final class PanelVersioningTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let panelPath = "/Users/puzhen/.fleetview/ui/panel.html"

    // MARK: - Capture decisions

    func testIdenticalContentIsNotArchivedTwice() {
        // The skill tells agents "just rewrite panel.html" for simple updates, so identical content
        // arrives constantly. Without this the archive fills with duplicates.
        let html = "<html><body>same</body></html>"
        let sha = PanelCapture.sha256(html)
        XCTAssertEqual(PanelCapture.decide(content: html, currentSHA: sha), .unchanged)
    }

    func testChangedContentIsCaptured() {
        let sha = PanelCapture.sha256("<html><body>old</body></html>")
        XCTAssertEqual(PanelCapture.decide(content: "<html><body>new</body></html>", currentSHA: sha), .capture)
    }

    func testFirstEverPanelIsCaptured() {
        XCTAssertEqual(PanelCapture.decide(content: "<html></html>", currentSHA: nil), .capture)
    }

    func testEmptyContentIsRejected() {
        XCTAssertEqual(PanelCapture.decide(content: "   \n ", currentSHA: nil), .invalid(reason: "empty"))
    }

    func testTruncationIsDetectedButNotFatal() {
        // `cat > panel.html <<'HTML'` is not atomic, so a half-written file is a real possibility.
        XCTAssertFalse(PanelCapture.looksComplete("<html><body><h1>half"))
        XCTAssertTrue(PanelCapture.looksComplete("<html><body>done</body></html>"))
        // A bare fragment is a legitimate panel and must not be flagged.
        XCTAssertTrue(PanelCapture.looksComplete("<div>just a fragment</div>"))
    }

    func testDigestIsStable() {
        XCTAssertEqual(PanelCapture.sha256("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Titles

    func testTitleComesFromTheDocumentTitle() {
        XCTAssertEqual(PanelCapture.title(fromHTML: "<html><head><title>CI 构建监控</title></head></html>"),
                       "CI 构建监控")
    }

    func testTitleFallsBackToTheFirstHeading() {
        XCTAssertEqual(PanelCapture.title(fromHTML: "<body><h1>Build progress</h1></body>"), "Build progress")
    }

    func testTitleStripsNestedMarkup() {
        XCTAssertEqual(PanelCapture.title(fromHTML: "<h1><span>Tests</span> running</h1>"), "Tests running")
    }

    func testTitlelessPanelIsAllowed() {
        XCTAssertNil(PanelCapture.title(fromHTML: "<div>no title here</div>"))
    }

    // MARK: - Which tool call wrote the panel

    func testWriteToolIsMatchedByPath() {
        XCTAssertTrue(PanelToolMatcher.isPanelWrite(tool: "Write",
                                                    input: ["file_path": panelPath],
                                                    panelPath: panelPath))
    }

    func testBashHeredocIsMatchedByCommand() {
        XCTAssertTrue(PanelToolMatcher.isPanelWrite(
            tool: "Bash",
            input: ["command": "mkdir -p ~/.fleetview/ui && cat > ~/.fleetview/ui/panel.html <<'HTML'"],
            panelPath: panelPath))
    }

    func testUnrelatedToolCallsDoNotMatch() {
        XCTAssertFalse(PanelToolMatcher.isPanelWrite(tool: "Write",
                                                     input: ["file_path": "/tmp/other.html"],
                                                     panelPath: panelPath))
        XCTAssertFalse(PanelToolMatcher.isPanelWrite(tool: "Bash",
                                                     input: ["command": "swift build"],
                                                     panelPath: panelPath))
        XCTAssertFalse(PanelToolMatcher.isPanelWrite(tool: nil, input: nil, panelPath: panelPath))
    }

    func testPanelDataWritesDoNotCountAsPanelWrites() {
        // panel.json is high-frequency data, not a version.
        XCTAssertFalse(PanelToolMatcher.isPanelWrite(
            tool: "Bash",
            input: ["command": "echo '{\"progress\":0.4}' > ~/.fleetview/ui/panel.json"],
            panelPath: panelPath))
    }

    // MARK: - Attribution

    private func signal(_ id: String, _ name: String, offset: TimeInterval = 0, tool: String? = nil) -> PanelWriteSignal {
        PanelWriteSignal(terminalID: id, terminalName: name, agentKind: "claude",
                         sessionID: "sess-\(id)", transcriptPath: "/p/\(id).jsonl",
                         tool: tool, at: now.addingTimeInterval(offset))
    }

    func testAHookMatchWinsOutright() {
        let result = PanelAttributionResolver.resolve(
            signals: [signal("t1", "api-refactor", offset: -2, tool: "Write")],
            active: [signal("t2", "other"), signal("t3", "third")],
            at: now)
        XCTAssertEqual(result.method, .hookToolMatch)
        XCTAssertEqual(result.terminalName, "api-refactor")
        XCTAssertEqual(result.sessionID, "sess-t1")
        XCTAssertEqual(result.transcriptPath, "/p/t1.jsonl")
        XCTAssertEqual(result.tool, "Write")
    }

    func testTheMostRecentHookMatchWins() {
        let result = PanelAttributionResolver.resolve(
            signals: [signal("t1", "older", offset: -20, tool: "Write"),
                      signal("t2", "newer", offset: -1, tool: "Bash")],
            active: [], at: now)
        XCTAssertEqual(result.terminalName, "newer")
    }

    func testStaleHookMatchesAreIgnored() {
        let result = PanelAttributionResolver.resolve(
            signals: [signal("t1", "long ago", offset: -600, tool: "Write")],
            active: [], at: now)
        XCTAssertEqual(result.method, .unknown)
    }

    func testASingleActiveTerminalIsInferred() {
        let result = PanelAttributionResolver.resolve(signals: [], active: [signal("t9", "only-one")], at: now)
        XCTAssertEqual(result.method, .inferredSingleActive)
        XCTAssertEqual(result.terminalName, "only-one")
        XCTAssertEqual(result.sessionID, "sess-t9")
    }

    func testSeveralActiveTerminalsStayAmbiguous() {
        // Guessing would put a real conversation's name on someone else's work.
        let result = PanelAttributionResolver.resolve(
            signals: [], active: [signal("t1", "beta"), signal("t2", "alpha")], at: now)
        XCTAssertEqual(result.method, .ambiguous)
        XCTAssertEqual(result.candidates, ["alpha", "beta"])
        XCTAssertNil(result.terminalID)
    }

    func testNothingKnownIsRecordedAsUnknown() {
        let result = PanelAttributionResolver.resolve(signals: [], active: [], at: now)
        XCTAssertEqual(result.method, .unknown)
    }

    // MARK: - Version records

    private func version(uuid: String = "019820f1-7c3a-7c21-b8e4-1f2a3b4c5d6e",
                         previous: String? = nil,
                         derivedFrom: String? = nil) -> PanelVersion {
        PanelVersion(uuid: uuid,
                     sha256: "3b1f",
                     bytes: 7412,
                     title: "CI 构建监控",
                     previous: previous,
                     derivedFrom: derivedFrom,
                     attribution: PanelAttribution(method: .hookToolMatch,
                                                   terminalID: "3F2A", terminalName: "api-refactor",
                                                   agentKind: "claude", sessionID: "24fc7a41",
                                                   transcriptPath: "/p/24fc7a41.jsonl", tool: "Write"),
                     timestamp: now)
    }

    func testVersionFilenameIsTheUUID() {
        XCTAssertEqual(version().fileName, "019820f1-7c3a-7c21-b8e4-1f2a3b4c5d6e.html")
    }

    func testIndexLineIsValidJSONWithProvenance() throws {
        let formatter = TimestampFormatter(timeZone: TimeZone(identifier: "UTC")!)
        let line = version(previous: "019820e9").indexLine(formatter: formatter)
        XCTAssertFalse(line.contains("\n"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(json["uuid"] as? String, "019820f1-7c3a-7c21-b8e4-1f2a3b4c5d6e")
        XCTAssertEqual(json["title"] as? String, "CI 构建监控")
        XCTAssertEqual(json["prev"] as? String, "019820e9")
        // The user's actual requirement: which conversation file produced this HTML, and when.
        XCTAssertEqual(json["agent.session_id"] as? String, "24fc7a41")
        XCTAssertEqual(json["transcript"] as? String, "/p/24fc7a41.jsonl")
        XCTAssertEqual(json["ts"] as? String, "2023-11-14T22:13:20.000Z")
        XCTAssertEqual(json["attribution"] as? String, "hook_tool_match")
    }

    func testAuditDataCarriesTheSameProvenance() {
        let data = version().auditData
        XCTAssertEqual(data["panel.uuid"], .string("019820f1-7c3a-7c21-b8e4-1f2a3b4c5d6e"))
        XCTAssertEqual(data["agent.session.id"], .string("24fc7a41"))
        XCTAssertEqual(data["transcript.path"], .string("/p/24fc7a41.jsonl"))
        XCTAssertEqual(data["attribution.method"], .string("hook_tool_match"))
    }

    func testRollbackKeepsALinkToWhatItRestored() {
        // History is append-only: restoring an old panel makes a *new* version that points back.
        let restored = version(uuid: "019820ff", derivedFrom: "019820e9")
        XCTAssertEqual(restored.auditData["panel.derived_from"], .string("019820e9"))
    }

    func testAmbiguousAttributionListsCandidates() {
        let attribution = PanelAttribution(method: .ambiguous, candidates: ["alpha", "beta"])
        XCTAssertEqual(attribution.fields["attribution.candidates"],
                       .array([.string("alpha"), .string("beta")]))
        XCTAssertNil(attribution.fields["agent.session.id"])
    }
}
