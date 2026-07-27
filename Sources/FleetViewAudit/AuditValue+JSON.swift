import Foundation

extension AuditValue {
    /// Bridge from a Foundation JSON object — what `JSONSerialization` hands back after encoding a
    /// `Codable` model.
    ///
    /// This is how the app projects its models into audited fields: encode the struct, walk the
    /// dictionary. No per-type mapping to write, and therefore none to forget — a property added to
    /// a model shows up in the next snapshot on its own, which is the property the whole design
    /// depends on.
    public init(json: Any) {
        switch json {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            // JSONSerialization returns NSNumber for booleans too, and `as? Bool` would happily
            // turn the integer 1 into `true`. The CoreFoundation type is the only reliable tell.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if let int = Self.exactInt(value) {
                self = .int(int)
            } else {
                self = .double(value.doubleValue)
            }
        case let value as [Any]:
            self = .array(value.map { AuditValue(json: $0) })
        case let value as [String: Any]:
            self = .object(value.mapValues { AuditValue(json: $0) })
        case is NSNull:
            self = .null
        default:
            self = .string(String(describing: json))
        }
    }

    private static func exactInt(_ number: NSNumber) -> Int? {
        switch String(cString: number.objCType) {
        case "d", "f":
            return nil                       // genuinely fractional in the source type
        default:
            let d = number.doubleValue
            guard d == d.rounded(), abs(d) <= Double(Int.max) else { return nil }
            return number.intValue
        }
    }

    /// Encode any `Codable` value into audited fields.
    public static func fields<T: Encodable>(of value: T,
                                            dropping dropped: Set<String> = []) -> [String: AuditValue] {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return [:] }
        var out: [String: AuditValue] = [:]
        for (key, raw) in dictionary where !dropped.contains(key) {
            out[key] = AuditValue(json: raw)
        }
        return out
    }
}
