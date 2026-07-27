import Foundation

/// The one object the app talks to.
///
/// Two entry points, and only two:
///
/// * `record(from:to:intent:)` — hand it two state snapshots. Everything that changed becomes an
///   event, named by policy, attributed to the ambient actor. This is what makes a new button, a
///   new web endpoint or a new model field audited without anyone writing logging code for it.
/// * `emit(_:)` — for facts that are not state: a shell command ran, an HTTP request was refused,
///   a panel version was archived.
///
/// The actor and trace are never parameters. They come from `AuditContext`, which the entry points
/// (web request, hook dispatch) set once — the same division of labour paper_trail and
/// django-auditlog settled on, where the controller/middleware says *who* and the model layer says
/// *what*.
public final class Auditor: @unchecked Sendable {
    public let sink: AuditSink
    public var auditor: StateAuditor
    public var isEnabled: Bool

    public init(sink: AuditSink, policy: AuditPolicy = .fleetView, isEnabled: Bool = true) {
        self.sink = sink
        self.auditor = StateAuditor(policy: policy)
        self.isEnabled = isEnabled
    }

    /// A no-op auditor, so code paths that run before configuration (or in previews) don't need
    /// optional-chaining everywhere.
    public static let disabled = Auditor(sink: MemoryAuditSink(), isEnabled: false)

    // MARK: - State changes

    public func record(from before: AuditSnapshot,
                       to after: AuditSnapshot,
                       intent: AuditIntent? = nil,
                       at timestamp: Date = Date()) {
        guard isEnabled else { return }
        let changes = SnapshotDiff.changes(from: before, to: after)
        let events = auditor.events(for: changes,
                                    intent: intent,
                                    actor: AuditContext.actor,
                                    trace: AuditContext.trace,
                                    at: timestamp)
        for event in events { sink.write(event) }
    }

    // MARK: - Standalone facts

    public func emit(_ event: AuditEvent) {
        guard isEnabled else { return }
        var e = event
        if e.actor == nil { e.actor = AuditContext.actor }
        if e.trace == nil { e.trace = AuditContext.trace }
        sink.write(e)
    }

    public func emit(_ name: String,
                     kind: AuditEvent.Kind = .event,
                     categories: [String] = [],
                     types: [String] = [],
                     outcome: AuditEvent.Outcome = .success,
                     message: String? = nil,
                     target: AuditTarget? = nil,
                     data: [String: AuditValue] = [:],
                     durationNanos: Int? = nil) {
        emit(AuditEvent(name: name, kind: kind, categories: categories, types: types,
                        outcome: outcome, message: message, target: target,
                        data: data, durationNanos: durationNanos))
    }

    /// Record a failure. Kept as its own call because failures are the events a diff-based logger
    /// would otherwise miss entirely — nothing changed, so nothing would be written.
    public func failure(_ name: String,
                        reason: String,
                        categories: [String] = [],
                        target: AuditTarget? = nil,
                        data: [String: AuditValue] = [:]) {
        var payload = data
        payload["reason"] = .string(reason)
        emit(AuditEvent(name: name, kind: .alert, categories: categories,
                        outcome: .failure, message: reason, target: target, data: payload))
    }

    public func flush() { sink.flush() }
}
