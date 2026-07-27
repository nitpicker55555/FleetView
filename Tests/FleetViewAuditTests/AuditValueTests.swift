import Foundation
import FleetViewAudit

/// The encoder's guarantees are load-bearing: one event must be one line, and the same event must
/// always encode to the same bytes (tests and `jq` pipelines both depend on it).
final class AuditValueTests: XCTestCase {

    func testObjectKeysAreSorted() {
        let v = AuditValue.object(["zebra": 1, "alpha": 2, "middle": 3])
        XCTAssertEqual(v.json, #"{"alpha":2,"middle":3,"zebra":1}"#)
    }

    func testNewlinesAndTabsAreEscaped() {
        let v = AuditValue.string("line one\nline two\ttabbed")
        XCTAssertFalse(v.json.contains("\n"), "a raw newline would split one event across two lines")
        XCTAssertEqual(v.json, #""line one\nline two\ttabbed""#)
    }

    func testOtherControlCharactersBecomeUnicodeEscapes() throws {
        let bell = String(UnicodeScalar(0x07)!)
        let v = AuditValue.string("ring" + bell)
        XCTAssertFalse(v.json.unicodeScalars.contains { $0.value < 0x20 },
                       "a raw control character leaked into the line")
        let parsed = try JSONSerialization.jsonObject(with: Data("[\(v.json)]".utf8)) as? [String]
        XCTAssertEqual(parsed?.first, "ring" + bell, "escaping must round-trip")
    }

    func testQuotesAndBackslashesAreEscaped() {
        let v = AuditValue.string(#"say "hi" \ bye"#)
        XCTAssertEqual(v.json, #""say \"hi\" \\ bye""#)
    }

    func testIntegersAndBooleansDoNotCollapse() {
        // NSNumber-based encoders famously turn `true` into `1`; ours must not.
        XCTAssertEqual(AuditValue.bool(true).json, "true")
        XCTAssertEqual(AuditValue.int(1).json, "1")
    }

    func testWholeDoublesPrintWithoutDecimalPoint() {
        XCTAssertEqual(AuditValue.double(42).json, "42")
        XCTAssertEqual(AuditValue.double(0.5).json, "0.5")
    }

    func testNonFiniteDoublesBecomeNull() {
        // JSON has no NaN/Infinity — emitting one produces a file no parser can read.
        XCTAssertEqual(AuditValue.double(.nan).json, "null")
        XCTAssertEqual(AuditValue.double(.infinity).json, "null")
    }

    func testCompactDropsNilAndNull() {
        let out = AuditValue.compact(["a": .string("x"), "b": nil, "c": .null])
        XCTAssertEqual(out, ["a": .string("x")])
    }

    func testNestedStructuresEncode() {
        let v = AuditValue.object(["list": .array([1, "two", true, .null])])
        XCTAssertEqual(v.json, #"{"list":[1,"two",true,null]}"#)
    }

    func testEncodedOutputParsesAsJSON() {
        let v = AuditValue.object([
            "unicode": .string("终端 · 中文 🚀"),
            "nested": .object(["n": 1]),
        ])
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(v.json.utf8)))
    }

    func testCJKSurvivesRoundTrip() throws {
        let v = AuditValue.string("重构 API 终端")
        let parsed = try JSONSerialization.jsonObject(with: Data("{\"k\":\(v.json)}".utf8))
        let dict = try XCTUnwrap(parsed as? [String: Any])
        XCTAssertEqual(dict["k"] as? String, "重构 API 终端")
    }
}
