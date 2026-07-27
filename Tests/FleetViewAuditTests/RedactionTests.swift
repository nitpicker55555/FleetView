import Foundation
import FleetViewAudit

/// Shell command lines are the one place the audit log is likely to meet a real credential.
/// A log that records `export ANTHROPIC_API_KEY=sk-…` verbatim is a credential store with a
/// friendly filename.
final class RedactionTests: XCTestCase {

    private let redaction = Redaction()

    private func redact(_ s: String) -> String { redaction.apply(to: s).text }

    func testEnvironmentAssignmentIsMasked() {
        let out = redact("export ANTHROPIC_API_KEY=sk-ant-super-secret-value")
        XCTAssertTrue(out.contains("ANTHROPIC_API_KEY="))
        XCTAssertFalse(out.contains("super-secret-value"))
        XCTAssertTrue(out.contains(Redaction.mask))
    }

    func testPasswordAndTokenFlagsAreMasked() {
        XCTAssertFalse(redact("mysql --password hunter2").contains("hunter2"))
        XCTAssertFalse(redact("gh auth login --token ghp_aaaabbbbccccdddd").contains("ghp_aaaabbbbccccdddd"))
        XCTAssertFalse(redact("deploy --secret=topsecretvalue").contains("topsecretvalue"))
    }

    func testAuthorizationHeadersAreMasked() {
        let out = redact(#"curl -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig" https://api"#)
        XCTAssertFalse(out.contains("eyJhbGciOiJIUzI1NiJ9.payload.sig"))
        XCTAssertTrue(out.contains("Authorization"), "the fact that auth was used is still worth logging")
    }

    func testBasicAuthCredentialsAreMasked() {
        let out = redact("curl -u admin:letmein https://example.com")
        XCTAssertFalse(out.contains("letmein"))
        XCTAssertTrue(out.contains("admin"), "the username is context, not a secret")
    }

    func testWellKnownTokenShapesAreMaskedAnywhere() {
        XCTAssertFalse(redact("echo ghp_abcdefghijklmnopqrstuvwxyz012345").contains("abcdefghijklmnop"))
        XCTAssertFalse(redact("echo xoxb-1111-2222-abcdefghijklm").contains("abcdefghijklm"))
    }

    func testOrdinaryCommandsAreUntouched() {
        // False positives are their own kind of damage: an audit log you cannot read is useless.
        for command in ["swift build -c release",
                        "git commit -m 'fix the parser'",
                        "ls -la ~/.fleetview/logs",
                        "cd /Users/puzhen/PycharmProjects/FleetView && make test"] {
            XCTAssertEqual(redact(command), command)
            XCTAssertFalse(redaction.apply(to: command).redacted)
        }
    }

    func testRedactionIsReported() {
        XCTAssertTrue(redaction.apply(to: "export TOKEN=abc123").redacted)
        XCTAssertFalse(redaction.apply(to: "echo hello").redacted)
    }

    func testRedactionIsIdempotent() {
        let once = redact("export API_KEY=secret")
        XCTAssertEqual(redact(once), once, "re-running must not mangle an already-masked line")
    }
}
