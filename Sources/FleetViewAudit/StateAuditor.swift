import Foundation

/// A declared operation: what the caller *meant* to do.
///
/// Diffing alone is not a sufficient audit trail — the event-sourcing literature is blunt about it:
/// actions that don't change state leave no trace, so the narrative has gaps exactly where it
/// matters (a raise that only reorders windows, a keystroke sent straight to tmux, a request that
/// failed and therefore changed nothing). An intent is recorded whether or not state moved, which
/// closes that hole while still costing one wrapper per *model* method — never per button.
public struct AuditIntent: Sendable {
    public var name: String                    // "terminal.rename"
    /// Event name for the case where the operation changes no state and has to speak for itself.
    public var event: String?
    public var categories: [String]
    public var target: AuditTarget?
    public var data: [String: AuditValue]
    public var outcome: AuditEvent.Outcome
    public var message: String?

    public init(_ name: String,
                event: String? = nil,
                categories: [String] = [],
                target: AuditTarget? = nil,
                data: [String: AuditValue] = [:],
                outcome: AuditEvent.Outcome = .success,
                message: String? = nil) {
        self.name = name
        self.event = event
        self.categories = categories
        self.target = target
        self.data = data
        self.outcome = outcome
        self.message = message
    }
}

/// Turns snapshot changes (plus an optional declared intent) into audit events.
///
/// Pure and synchronous: given the same inputs it produces the same events in the same order, which
/// is what lets the whole behaviour be pinned down by unit tests instead of by running the app.
public struct StateAuditor: Sendable {
    public var policy: AuditPolicy

    public init(policy: AuditPolicy = .fleetView) {
        self.policy = policy
    }

    public func events(for changes: [AuditChange],
                       intent: AuditIntent? = nil,
                       actor: AuditActor,
                       trace: AuditTrace? = nil,
                       at timestamp: Date = Date()) -> [AuditEvent] {
        var out: [AuditEvent] = []
        for change in changes {
            out.append(contentsOf: events(for: change, intent: intent, actor: actor,
                                          trace: trace, at: timestamp))
        }
        // The operation happened but moved nothing: still a fact, and often the interesting one.
        if out.isEmpty, let intent {
            out.append(intentOnlyEvent(intent, actor: actor, trace: trace, at: timestamp))
        }
        return out
    }

    private func events(for change: AuditChange,
                        intent: AuditIntent?,
                        actor: AuditActor,
                        trace: AuditTrace?,
                        at timestamp: Date) -> [AuditEvent] {
        let entity = change.entity
        let rule = policy.rule(for: entity.kind)

        switch change {
        case .added(let e):
            guard let name = rule.createdEvent else { return [] }
            var data = e.fields.filter { !rule.ignored.contains($0.key) && !$0.value.isEmpty }
            merge(intent, into: &data)
            return [AuditEvent(name: name, categories: rule.categories, types: ["creation"],
                               outcome: intent?.outcome ?? .success,
                               message: "\(e.kind) \(quoted(e.label ?? e.id)) created",
                               actor: actor, target: e.target, trace: trace,
                               data: data, timestamp: timestamp)]

        case .removed(let e):
            guard let name = rule.removedEvent else { return [] }
            var data: [String: AuditValue] = [:]
            merge(intent, into: &data)
            return [AuditEvent(name: name, categories: rule.categories, types: ["deletion"],
                               outcome: intent?.outcome ?? .success,
                               message: "\(e.kind) \(quoted(e.label ?? e.id)) removed",
                               actor: actor, target: e.target, trace: trace,
                               data: data, timestamp: timestamp)]

        case .modified(let before, let after, let fields):
            return modifiedEvents(before: before, after: after, fields: fields, rule: rule,
                                  intent: intent, actor: actor, trace: trace, at: timestamp)
        }
    }

    private func modifiedEvents(before: AuditEntity,
                                after: AuditEntity,
                                fields: [FieldChange],
                                rule: AuditPolicy.EntityRule,
                                intent: AuditIntent?,
                                actor: AuditActor,
                                trace: AuditTrace?,
                                at timestamp: Date) -> [AuditEvent] {
        var semanticGroups: [String: (semantic: AuditPolicy.Semantic, fields: [FieldChange])] = [:]
        var generic: [FieldChange] = []

        for field in fields where !rule.ignored.contains(field.key) {
            if let semantic = rule.semantic[field.key] {
                // Several fields can name the same event (transcript path + session id are one
                // fact); collect them so they produce one record, not one each.
                semanticGroups[semantic.event, default: (semantic, [])].fields.append(field)
            } else {
                generic.append(field)
            }
        }

        var out: [AuditEvent] = []
        for name in semanticGroups.keys.sorted() {
            let group = semanticGroups[name]!
            var data: [String: AuditValue] = [:]
            for field in group.fields {
                let semantic = rule.semantic[field.key] ?? group.semantic
                if let b = field.before, !b.isEmpty { data[semantic.fromKey] = b }
                if let a = field.after, !a.isEmpty { data[semantic.toKey] = a }
            }
            merge(intent, into: &data)
            out.append(AuditEvent(name: name, categories: rule.categories, types: group.semantic.types,
                                  outcome: intent?.outcome ?? .success,
                                  message: message(for: group.fields, entity: after),
                                  actor: actor, target: after.target, trace: trace,
                                  data: data, timestamp: timestamp))
        }

        if !generic.isEmpty {
            // Nothing classified these — log them anyway. A field that nobody thought about is
            // exactly the field a silent-drop policy would lose.
            var data: [String: AuditValue] = [
                "fields": .array(generic.map { .string($0.key) }),
            ]
            for field in generic {
                if let b = field.before, !b.isEmpty { data["\(field.key).from"] = b }
                if let a = field.after, !a.isEmpty { data["\(field.key).to"] = a }
            }
            merge(intent, into: &data)
            out.append(AuditEvent(name: rule.changedEvent, categories: rule.categories, types: ["change"],
                                  outcome: intent?.outcome ?? .success,
                                  message: message(for: generic, entity: after),
                                  actor: actor, target: after.target, trace: trace,
                                  data: data, timestamp: timestamp))
        }
        return out
    }

    private func intentOnlyEvent(_ intent: AuditIntent,
                                 actor: AuditActor,
                                 trace: AuditTrace?,
                                 at timestamp: Date) -> AuditEvent {
        var data = intent.data
        data["intent"] = .string(intent.name)
        return AuditEvent(name: intent.event ?? "fleetview.\(intent.name)",
                          kind: intent.outcome == .failure ? .alert : .event,
                          categories: intent.categories,
                          outcome: intent.outcome,
                          message: intent.message ?? intent.name,
                          actor: actor,
                          target: intent.target,
                          trace: trace,
                          data: data,
                          timestamp: timestamp)
    }

    /// The declared operation rides along on every event it caused, so a status flip driven by a
    /// hook is distinguishable from one a person caused by clicking something.
    private func merge(_ intent: AuditIntent?, into data: inout [String: AuditValue]) {
        guard let intent else { return }
        data["intent"] = .string(intent.name)
        for (k, v) in intent.data where data[k] == nil { data[k] = v }
    }

    private func message(for fields: [FieldChange], entity: AuditEntity) -> String {
        let label = quoted(entity.label ?? entity.id)
        let parts = fields.prefix(3).map { field -> String in
            let before = field.before?.displayString ?? "—"
            let after = field.after?.displayString ?? "—"
            return "\(field.key) \(before) → \(after)"
        }
        let more = fields.count > 3 ? " (+\(fields.count - 3) more)" : ""
        return "\(entity.kind) \(label): \(parts.joined(separator: ", "))\(more)"
    }

    private func quoted(_ s: String) -> String { "\"\(s)\"" }
}
