import Foundation

/// A JSON value used for audited field values and event payloads.
///
/// Why a closed enum rather than `Any`/`AnyCodable`: the state differ compares two snapshots field
/// by field, and `Any` can't be compared without a pile of casts. `Equatable` here is what makes
/// change detection a one-liner. It also lets the encoder guarantee properties the log format
/// depends on — sorted keys (stable `jq` output and stable test expectations) and never a raw
/// newline (one event *must* be one line).
public enum AuditValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AuditValue])
    case object([String: AuditValue])
}

// MARK: - Literals (keeps call sites readable: ["port": 8080, "ok": true])

extension AuditValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension AuditValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}
extension AuditValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension AuditValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension AuditValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Convenience constructors

extension AuditValue {
    /// An optional string, collapsing `nil` to `.null` (callers usually want the key omitted
    /// instead — see `AuditValue.compact` — but explicit null is occasionally meaningful, e.g.
    /// "the previous selection was nothing").
    public init(_ value: String?) { self = value.map { .string($0) } ?? .null }
    public init(_ value: Int?) { self = value.map { .int($0) } ?? .null }
    public init(_ value: Bool?) { self = value.map { .bool($0) } ?? .null }

    /// Drop `nil` entries so events don't carry `"field": null` noise. The spec's rule is
    /// "unknown/not-applicable fields are omitted, never written as null".
    public static func compact(_ pairs: [String: AuditValue?]) -> [String: AuditValue] {
        pairs.reduce(into: [:]) { out, pair in
            if let v = pair.value, v != .null { out[pair.key] = v }
        }
    }

    /// The scalar as a display string, for building human-readable `message` fields.
    public var displayString: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "—"
        case .array, .object: return json
        }
    }

    /// True for values that carry no information (used to decide whether a field "appeared").
    public var isEmpty: Bool {
        switch self {
        case .null: return true
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        case .object(let o): return o.isEmpty
        default: return false
        }
    }
}

// MARK: - Encoding

extension AuditValue {
    /// Compact JSON, keys sorted, guaranteed newline-free.
    ///
    /// Hand-rolled rather than `JSONSerialization` because the sink's atomicity guarantee rests on
    /// "one event is exactly one `write(2)` of one line": we need certainty that no control
    /// character survives, and certainty about key order (JSONSerialization's `.sortedKeys` sorts,
    /// but round-tripping through `Any` would first lose our type distinctions — Int vs Bool most
    /// painfully, since `NSNumber` conflates them).
    public var json: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            // JSON has no NaN/Infinity; emitting them produces a file that no parser can read.
            out += d.isFinite ? Self.formatDouble(d) : "null"
        case .string(let s):
            Self.writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let dict):
            out += "{"
            for (i, key) in dict.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                Self.writeString(key, into: &out)
                out += ":"
                dict[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    /// Whole doubles print as `1` rather than `1.0` so token counts and durations read naturally.
    private static func formatDouble(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":     out += "\\\""
            case "\\":     out += "\\\\"
            case "\n":     out += "\\n"
            case "\r":     out += "\\r"
            case "\t":     out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
