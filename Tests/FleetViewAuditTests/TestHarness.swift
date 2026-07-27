import Foundation

// A ~100-line stand-in for XCTest.
//
// This machine has Command Line Tools but no full Xcode, so neither XCTest nor swift-testing is
// available to SwiftPM — `swift test` cannot run at all. Rather than ship an untested audit engine,
// the suite runs as a plain executable: `swift run FleetViewAuditTests`.
//
// The assertions deliberately keep XCTest's names and signatures, so the test bodies are the ones
// you would write against XCTest. If a full Xcode is ever installed, the migration is: flip the
// target back to `.testTarget`, add `import XCTest`, delete this file and `main.swift`.

struct Test {
    let name: String
    let run: () throws -> Void

    init(_ name: String, _ run: @escaping () throws -> Void) {
        self.name = name
        self.run = run
    }
}

/// Base class so test types can keep XCTest's shape (`setUp`/`tearDown`).
class XCTestCase {
    required init() {}
    func setUp() {}
    func tearDown() {}
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

enum TestReporter {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var assertions = 0

    static func fail(_ message: String, _ file: StaticString, _ line: UInt) {
        let location = "\(URL(fileURLWithPath: String(describing: file)).lastPathComponent):\(line)"
        failures.append("\(location) — \(message)")
    }

    static func record() { assertions += 1 }
}

// MARK: - Assertions (XCTest-compatible names)

func XCTFail(_ message: String = "failed", file: StaticString = #filePath, line: UInt = #line) {
    TestReporter.record()
    TestReporter.fail(message, file, line)
}

func XCTAssertTrue(_ value: Bool, _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    TestReporter.record()
    if !value { TestReporter.fail(message().isEmpty ? "expected true" : message(), file, line) }
}

func XCTAssertFalse(_ value: Bool, _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    TestReporter.record()
    if value { TestReporter.fail(message().isEmpty ? "expected false" : message(), file, line) }
}

func XCTAssertEqual<V: Equatable>(_ a: V?, _ b: V?, _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    TestReporter.record()
    guard a != b else { return }
    let detail = "expected \(describe(b)), got \(describe(a))"
    TestReporter.fail(message().isEmpty ? detail : "\(message()) — \(detail)", file, line)
}

func XCTAssertNotEqual<V: Equatable>(_ a: V?, _ b: V?, _ message: @autoclosure () -> String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
    TestReporter.record()
    if a == b { TestReporter.fail(message().isEmpty ? "expected values to differ" : message(), file, line) }
}

func XCTAssertLessThan<V: Comparable>(_ a: V, _ b: V, _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    TestReporter.record()
    if !(a < b) { TestReporter.fail(message().isEmpty ? "expected \(a) < \(b)" : message(), file, line) }
}

func XCTAssertLessThanOrEqual<V: Comparable>(_ a: V, _ b: V, _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    TestReporter.record()
    if !(a <= b) { TestReporter.fail(message().isEmpty ? "expected \(a) <= \(b)" : message(), file, line) }
}

func XCTAssertNil(_ value: Any?, _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) {
    TestReporter.record()
    if value != nil {
        TestReporter.fail(message().isEmpty ? "expected nil, got \(value!)" : message(), file, line)
    }
}

func XCTAssertNotNil(_ value: Any?, _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
    TestReporter.record()
    if value == nil { TestReporter.fail(message().isEmpty ? "expected non-nil" : message(), file, line) }
}

func XCTUnwrap<V>(_ value: V?, _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) throws -> V {
    TestReporter.record()
    guard let value else {
        let detail = message().isEmpty ? "unexpected nil" : message()
        TestReporter.fail(detail, file, line)
        throw TestFailure(description: detail)
    }
    return value
}

func XCTAssertThrowsError<V>(_ expression: @autoclosure () throws -> V,
                             _ message: @autoclosure () -> String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
    TestReporter.record()
    do {
        _ = try expression()
        TestReporter.fail(message().isEmpty ? "expected an error to be thrown" : message(), file, line)
    } catch {
        // expected
    }
}

func XCTAssertNoThrow<V>(_ expression: @autoclosure () throws -> V,
                         _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    TestReporter.record()
    do { _ = try expression() } catch {
        TestReporter.fail(message().isEmpty ? "unexpected error: \(error)" : message(), file, line)
    }
}

private func describe(_ value: Any?) -> String {
    guard let value else { return "nil" }
    return "\(value)"
}

// MARK: - Runner

enum TestRunner {
    static func run(_ suites: [(String, [Test])]) -> Int32 {
        var passed = 0
        var failedNames: [String] = []

        for (suiteName, tests) in suites {
            print("\n\(suiteName)")
            for test in tests {
                TestReporter.failures = []
                do {
                    try test.run()
                } catch {
                    TestReporter.failures.append("threw: \(error)")
                }
                if TestReporter.failures.isEmpty {
                    passed += 1
                    print("  ✓ \(test.name)")
                } else {
                    failedNames.append("\(suiteName) › \(test.name)")
                    print("  ✗ \(test.name)")
                    for failure in TestReporter.failures { print("      \(failure)") }
                }
            }
        }

        let total = passed + failedNames.count
        print("\n\(passed)/\(total) tests passed, \(TestReporter.assertions) assertions")
        if !failedNames.isEmpty {
            print("\nfailed:")
            for name in failedNames { print("  \(name)") }
            return 1
        }
        return 0
    }
}
