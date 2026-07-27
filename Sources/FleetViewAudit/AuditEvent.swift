import Foundation

/// Who performed an action.
///
/// Supplied by the *entry point* (web request, hook event, CLI call), never by the view layer —
/// the same pattern paper_trail calls `whodunnit` and django-auditlog sets from its middleware.
/// See `AuditContext` for how it reaches the code that actually mutates state.
public struct AuditActor: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case desktop   // the macOS UI
        case web       // a browser on the LAN / tailnet
        case cli       // fleetctl, project-manager, fleet-monitor, cron scripts
        case agent     // Claude / Codex, via their hooks
        case shell     // the zsh integration in a FleetView terminal
        case system    // FleetView itself: timers, restore-on-launch, teardown
    }

    public var kind: Kind
    public var id: String?
    public var name: String?
    public var userName: String?
    public var agentKind: String?     // "claude" | "codex"
    public var cliTool: String?
    public var sourceIP: String?
    public var sourcePort: Int?
    public var userAgent: String?
    public var geo: [String: AuditValue]
    public var extra: [String: AuditValue]

    public init(kind: Kind,
                id: String? = nil,
                name: String? = nil,
                userName: String? = nil,
                agentKind: String? = nil,
                cliTool: String? = nil,
                sourceIP: String? = nil,
                sourcePort: Int? = nil,
                userAgent: String? = nil,
                geo: [String: AuditValue] = [:],
                extra: [String: AuditValue] = [:]) {
        self.kind = kind
        self.id = id
        self.name = name
        self.userName = userName
        self.agentKind = agentKind
        self.cliTool = cliTool
        self.sourceIP = sourceIP
        self.sourcePort = sourcePort
        self.userAgent = userAgent
        self.geo = geo
        self.extra = extra
    }

    public static let system = AuditActor(kind: .system)

    var payload: [String: AuditValue] {
        var out = AuditValue.compact([
            "type": .string(kind.rawValue),
            "id": id.map { .string($0) },
            "name": name.map { .string($0) },
            "user.name": userName.map { .string($0) },
            "agent.kind": agentKind.map { .string($0) },
            "cli.tool": cliTool.map { .string($0) },
        ])
        for (k, v) in extra { out[k] = v }
        return out
    }
}

/// What was acted upon. `fields` carries the flattened resource context the spec asks for —
/// terminal id *and* name, its cluster, its project — so a log line is readable without joins.
public struct AuditTarget: Equatable, Sendable {
    public var kind: String
    public var id: String?
    public var name: String?
    public var fields: [String: AuditValue]

    public init(kind: String, id: String? = nil, name: String? = nil, fields: [String: AuditValue] = [:]) {
        self.kind = kind
        self.id = id
        self.name = name
        self.fields = fields
    }

    var payload: [String: AuditValue] {
        var out: [String: AuditValue] = ["kind": .string(kind)]
        if let id { out["\(kind).id"] = .string(id) }
        if let name { out["\(kind).name"] = .string(name) }
        for (k, v) in fields where !v.isEmpty { out[k] = v }
        return out
    }
}

/// Correlation ids, so one user intent can be followed from a tap or an HTTP request all the way
/// to the hook event it eventually provokes.
public struct AuditTrace: Equatable, Sendable {
    public var id: String?
    public var parent: String?
    public var requestID: String?
    public var webSessionID: String?

    public init(id: String? = nil, parent: String? = nil, requestID: String? = nil, webSessionID: String? = nil) {
        self.id = id
        self.parent = parent
        self.requestID = requestID
        self.webSessionID = webSessionID
    }

    var isEmpty: Bool { id == nil && parent == nil && requestID == nil && webSessionID == nil }

    var payload: [String: AuditValue] {
        AuditValue.compact([
            "id": id.map { .string($0) },
            "parent": parent.map { .string($0) },
            "request_id": requestID.map { .string($0) },
            "web_session_id": webSessionID.map { .string($0) },
        ])
    }
}

/// One audited fact. Deliberately *not* Codable: the wire format is ECS-shaped with dotted keys
/// that don't map cleanly onto Swift property names, and we need exact control over key order and
/// omission of empty values, so encoding is explicit (see `AuditEnvelope`).
public struct AuditEvent: Sendable {
    public enum Kind: String, Sendable {
        case event   // something happened
        case alert   // something that warrants attention (failures, denials)
        case state   // a periodic rollup / snapshot
    }

    public enum Outcome: String, Sendable {
        case success, failure, unknown
    }

    public var name: String                    // fleetview.terminal.created
    public var kind: Kind
    public var categories: [String]            // ECS event.category
    public var types: [String]                 // ECS event.type
    public var action: String?
    public var outcome: Outcome
    public var message: String?
    /// `nil` means "whoever the ambient `AuditContext` says" — which is the normal case, and the
    /// reason call sites never have to pass an actor around.
    public var actor: AuditActor?
    public var target: AuditTarget?
    public var trace: AuditTrace?
    public var data: [String: AuditValue]
    public var durationNanos: Int?
    public var timestamp: Date

    public init(name: String,
                kind: Kind = .event,
                categories: [String] = [],
                types: [String] = [],
                action: String? = nil,
                outcome: Outcome = .success,
                message: String? = nil,
                actor: AuditActor? = nil,
                target: AuditTarget? = nil,
                trace: AuditTrace? = nil,
                data: [String: AuditValue] = [:],
                durationNanos: Int? = nil,
                timestamp: Date = Date()) {
        self.name = name
        self.kind = kind
        self.categories = categories
        self.types = types
        self.action = action
        self.outcome = outcome
        self.message = message
        self.actor = actor
        self.target = target
        self.trace = trace
        self.data = data
        self.durationNanos = durationNanos
        self.timestamp = timestamp
    }

    public var resolvedActor: AuditActor { actor ?? .system }

    /// `fleetview.terminal.created` → `terminal.created`, used to derive a default ECS action.
    var shortName: String {
        name.hasPrefix("fleetview.") ? String(name.dropFirst("fleetview.".count)) : name
    }
}

/// Process-wide facts that every line repeats (OpenTelemetry calls this the "resource").
/// Held by the sink rather than copied into every event.
public struct AuditResource: Sendable {
    public var serviceName: String
    public var serviceVersion: String
    public var hostName: String
    public var osVersion: String
    public var pid: Int
    public var instanceID: String
    public var schemaVersion: Int

    public init(serviceName: String = "FleetView",
                serviceVersion: String = "dev",
                hostName: String = ProcessInfo.processInfo.hostName,
                osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                pid: Int = Int(ProcessInfo.processInfo.processIdentifier),
                instanceID: String = Identifiers.shortRandom(),
                schemaVersion: Int = 1) {
        self.serviceName = serviceName
        self.serviceVersion = serviceVersion
        self.hostName = hostName
        self.osVersion = osVersion
        self.pid = pid
        self.instanceID = instanceID
        self.schemaVersion = schemaVersion
    }
}
