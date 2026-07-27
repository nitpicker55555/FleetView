import Foundation

/// Renders an `AuditEvent` as the one JSON line that lands in the log.
///
/// The wire format is ECS-shaped (`@timestamp`, `event.*`, `source.ip`, `user_agent.original`)
/// with everything FleetView-specific under a single `fleetview.*` namespace, which is what ECS
/// prescribes for custom fields. Key order is fixed rather than alphabetical: the log is read by a
/// human with `jq` and `grep` at least as often as by a machine, and burying `message` between
/// `host.*` and `process.pid` makes a tail unreadable.
enum AuditEnvelope {
    static let ecsVersion = "8.11.0"

    static func line(event: AuditEvent,
                     resource: AuditResource,
                     id: String,
                     sequence: Int,
                     formatter: TimestampFormatter) -> String {
        var pairs: [(String, AuditValue)] = [
            ("@timestamp", .string(formatter.string(from: event.timestamp))),
            ("event.name", .string(event.name)),
            ("event.kind", .string(event.kind.rawValue)),
        ]

        if !event.categories.isEmpty { pairs.append(("event.category", .array(event.categories.map { .string($0) }))) }
        if !event.types.isEmpty { pairs.append(("event.type", .array(event.types.map { .string($0) }))) }
        pairs.append(("event.action", .string(event.action ?? defaultAction(for: event))))
        pairs.append(("event.outcome", .string(event.outcome.rawValue)))
        if let d = event.durationNanos { pairs.append(("event.duration", .int(d))) }
        pairs.append(("event.id", .string(id)))
        pairs.append(("event.sequence", .int(sequence)))
        pairs.append(("event.dataset", .string("fleetview.audit")))
        pairs.append(("event.module", .string("fleetview")))
        if let m = event.message, !m.isEmpty { pairs.append(("message", .string(m))) }

        // ECS top-level network/client fields, so an off-the-shelf collector understands them
        // without a transform. Only present for actors that actually came over the network.
        let actor = event.resolvedActor
        if let ip = actor.sourceIP { pairs.append(("source.ip", .string(ip))) }
        if let port = actor.sourcePort { pairs.append(("source.port", .int(port))) }
        if let ua = actor.userAgent { pairs.append(("user_agent.original", .string(ua))) }
        for key in actor.geo.keys.sorted() { pairs.append((key, actor.geo[key]!)) }

        pairs.append(("fleetview.schema", .int(resource.schemaVersion)))
        pairs.append(("fleetview.instance.id", .string(resource.instanceID)))
        pairs.append(("fleetview.actor", .object(actor.payload)))
        if let target = event.target { pairs.append(("fleetview.target", .object(target.payload))) }
        if let trace = event.trace, !trace.isEmpty { pairs.append(("fleetview.trace", .object(trace.payload))) }
        if !event.data.isEmpty { pairs.append(("fleetview.data", .object(event.data))) }

        pairs.append(("service.name", .string(resource.serviceName)))
        pairs.append(("service.version", .string(resource.serviceVersion)))
        pairs.append(("host.name", .string(resource.hostName)))
        pairs.append(("host.os.version", .string(resource.osVersion)))
        pairs.append(("process.pid", .int(resource.pid)))
        pairs.append(("ecs.version", .string(ecsVersion)))

        return encode(pairs)
    }

    /// `fleetview.terminal.created` → `terminal-created`. ECS's `event.action` is free-form, so we
    /// derive it mechanically rather than trying to conjugate English — a rule that turns "added"
    /// into "adde" is worse than no rule.
    static func defaultAction(for event: AuditEvent) -> String {
        event.shortName.replacingOccurrences(of: ".", with: "-")
    }

    /// JSON object encoding that preserves the given key order (nested objects still sort their
    /// own keys, which keeps diffs and test expectations stable).
    static func encode(_ pairs: [(String, AuditValue)]) -> String {
        var out = "{"
        for (i, pair) in pairs.enumerated() {
            if i > 0 { out += "," }
            AuditValue.writeString(pair.0, into: &out)
            out += ":"
            out += pair.1.json
        }
        out += "}"
        return out
    }
}

/// ISO 8601 with milliseconds **and a local UTC offset**.
///
/// Not UTC-with-Z: when you are reading back why a terminal died at 02:14, the number you want is
/// the one your wall clock showed. The offset keeps it unambiguous for machines.
public final class TimestampFormatter: @unchecked Sendable {
    private let formatter: ISO8601DateFormatter
    private let lock = NSLock()

    public init(timeZone: TimeZone = .current) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = timeZone
        formatter = f
    }

    public func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}
