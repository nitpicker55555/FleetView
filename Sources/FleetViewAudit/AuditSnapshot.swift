import Foundation

/// One audited resource, flattened to plain JSON fields.
///
/// The app projects its models into these (a `Codable` round-trip is enough), which is what keeps
/// this whole module free of any dependency on FleetView's types — and what makes the differ
/// testable with nothing but literals.
public struct AuditEntity: Equatable, Sendable {
    public let kind: String              // "terminal" | "cluster" | "project" | "note" | "ui"
    public let id: String
    public var label: String?            // human name, used to write readable messages
    public var fields: [String: AuditValue]
    /// Resource context repeated onto every event about this entity (project name, cluster name)
    /// so a single log line answers "which project was this?" without a join.
    public var context: [String: AuditValue]

    public init(kind: String,
                id: String,
                label: String? = nil,
                fields: [String: AuditValue] = [:],
                context: [String: AuditValue] = [:]) {
        self.kind = kind
        self.id = id
        self.label = label
        self.fields = fields
        self.context = context
    }

    public var key: String { "\(kind):\(id)" }

    public var target: AuditTarget {
        AuditTarget(kind: kind, id: id, name: label, fields: context)
    }
}

/// An immutable projection of everything worth auditing at one instant.
public struct AuditSnapshot: Equatable, Sendable {
    public private(set) var entities: [String: AuditEntity]

    public init(_ entities: [AuditEntity] = []) {
        self.entities = Dictionary(entities.map { ($0.key, $0) }, uniquingKeysWith: { _, b in b })
    }

    public var isEmpty: Bool { entities.isEmpty }
    public subscript(kind: String, id: String) -> AuditEntity? { entities["\(kind):\(id)"] }
}

public struct FieldChange: Equatable, Sendable {
    public let key: String
    public let before: AuditValue?
    public let after: AuditValue?

    public init(key: String, before: AuditValue?, after: AuditValue?) {
        self.key = key
        self.before = before
        self.after = after
    }
}

public enum AuditChange: Equatable, Sendable {
    case added(AuditEntity)
    case removed(AuditEntity)
    case modified(before: AuditEntity, after: AuditEntity, fields: [FieldChange])

    public var entity: AuditEntity {
        switch self {
        case .added(let e), .removed(let e): return e
        case .modified(_, let after, _): return after
        }
    }
}

public enum SnapshotDiff {
    /// Field-level change detection between two snapshots.
    ///
    /// This is the mechanism that makes new UI free: anything that mutates state shows up here,
    /// whether it came from a button that existed for years, a web endpoint added last week, or a
    /// model field added five minutes ago. Nothing has to be registered.
    ///
    /// Results are ordered deterministically (by entity key) — the log is diffed in tests, and a
    /// dictionary's iteration order is not something to build a file format on.
    public static func changes(from old: AuditSnapshot, to new: AuditSnapshot) -> [AuditChange] {
        var out: [AuditChange] = []
        for key in Set(old.entities.keys).union(new.entities.keys).sorted() {
            switch (old.entities[key], new.entities[key]) {
            case (nil, let after?):
                out.append(.added(after))
            case (let before?, nil):
                out.append(.removed(before))
            case (let before?, let after?):
                let fields = fieldChanges(from: before.fields, to: after.fields)
                if !fields.isEmpty { out.append(.modified(before: before, after: after, fields: fields)) }
            case (nil, nil):
                continue
            }
        }
        return out
    }

    static func fieldChanges(from old: [String: AuditValue], to new: [String: AuditValue]) -> [FieldChange] {
        Set(old.keys).union(new.keys).sorted().compactMap { key in
            let before = old[key]
            let after = new[key]
            guard before != after else { return nil }
            return FieldChange(key: key, before: before, after: after)
        }
    }
}
