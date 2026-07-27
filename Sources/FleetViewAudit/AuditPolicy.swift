import Foundation

/// How a field-level change becomes a named event.
///
/// The policy is *data*, not code, and it fails open: a field nobody has classified still produces
/// a generic `…changed` event rather than vanishing. That default is the whole point — add a
/// property to a model a year from now and it is audited the moment it is written, with no one
/// having to remember to log it.
public struct AuditPolicy: Sendable {
    /// A field whose change has its own name, e.g. `status` → `fleetview.terminal.status_changed`.
    public struct Semantic: Sendable {
        public var event: String
        public var fromKey: String
        public var toKey: String
        public var types: [String]

        public init(event: String, fromKey: String, toKey: String, types: [String] = ["change"]) {
            self.event = event
            self.fromKey = fromKey
            self.toKey = toKey
            self.types = types
        }
    }

    public struct EntityRule: Sendable {
        public var categories: [String]
        public var createdEvent: String?
        public var removedEvent: String?
        public var changedEvent: String
        /// Fields whose changes are logged elsewhere (or are pure derived noise). Listing a field
        /// here is a deliberate act of suppression — see §6 rule 4, "one fact, one writer".
        public var ignored: Set<String>
        public var semantic: [String: Semantic]

        public init(categories: [String] = [],
                    createdEvent: String? = nil,
                    removedEvent: String? = nil,
                    changedEvent: String,
                    ignored: Set<String> = [],
                    semantic: [String: Semantic] = [:]) {
            self.categories = categories
            self.createdEvent = createdEvent
            self.removedEvent = removedEvent
            self.changedEvent = changedEvent
            self.ignored = ignored
            self.semantic = semantic
        }
    }

    public var entities: [String: EntityRule]
    public var fallback: EntityRule

    public init(entities: [String: EntityRule], fallback: EntityRule) {
        self.entities = entities
        self.fallback = fallback
    }

    public func rule(for kind: String) -> EntityRule {
        entities[kind] ?? EntityRule(categories: fallback.categories,
                                     createdEvent: "fleetview.\(kind).created",
                                     removedEvent: "fleetview.\(kind).removed",
                                     changedEvent: "fleetview.\(kind).changed")
    }
}

extension AuditPolicy {
    /// FleetView's own policy. Field names match the `Codable` keys of the app's models, because
    /// snapshots are produced by encoding those models — that coupling is intentional and is what
    /// makes new model fields audited for free.
    public static let fleetView = AuditPolicy(
        entities: [
            "terminal": EntityRule(
                categories: ["process"],
                createdEvent: "fleetview.terminal.created",
                removedEvent: "fleetview.terminal.removed",
                changedEvent: "fleetview.terminal.changed",
                // lastActivity/newTokens move on every tick; lastPrompt is already carried by
                // agent.prompt_submitted and shell.command_started. Logging them here would be
                // the same fact written twice, at a much higher rate.
                ignored: ["lastActivity", "newTokens", "lastPrompt"],
                semantic: [
                    "name": Semantic(event: "fleetview.terminal.renamed",
                                     fromKey: "name.from", toKey: "name.to"),
                    "status": Semantic(event: "fleetview.terminal.status_changed",
                                       fromKey: "status.from", toKey: "status.to"),
                    "clusterId": Semantic(event: "fleetview.terminal.cluster_changed",
                                          fromKey: "cluster.from", toKey: "cluster.to"),
                    "subtaskDone": Semantic(event: "fleetview.terminal.done_toggled",
                                            fromKey: "done.from", toKey: "done.to"),
                    "agentKind": Semantic(event: "fleetview.terminal.agent_detected",
                                          fromKey: "agent.from", toKey: "agent.to"),
                    // Both fields describe the same fact ("this terminal now points at that
                    // conversation"), so they intentionally collapse into one event.
                    "transcriptPath": Semantic(event: "fleetview.terminal.transcript_bound",
                                               fromKey: "transcript.from", toKey: "transcript.to"),
                    "sessionId": Semantic(event: "fleetview.terminal.transcript_bound",
                                          fromKey: "session.from", toKey: "session.to"),
                ]),
            "cluster": EntityRule(
                categories: ["configuration"],
                createdEvent: "fleetview.cluster.created",
                removedEvent: "fleetview.cluster.removed",
                changedEvent: "fleetview.cluster.changed",
                semantic: [
                    "name": Semantic(event: "fleetview.cluster.renamed",
                                     fromKey: "name.from", toKey: "name.to"),
                ]),
            "project": EntityRule(
                categories: ["configuration"],
                createdEvent: "fleetview.project.added",
                removedEvent: "fleetview.project.removed",
                changedEvent: "fleetview.project.changed",
                semantic: [
                    "name": Semantic(event: "fleetview.project.renamed",
                                     fromKey: "name.from", toKey: "name.to"),
                ]),
            "note": EntityRule(
                categories: ["configuration"],
                createdEvent: "fleetview.note.added",
                removedEvent: "fleetview.note.removed",
                changedEvent: "fleetview.note.changed"),
            // A synthetic single-row entity for "what is the user looking at". Modelling selection
            // as state means clicks are diffed like everything else, instead of needing a log call
            // in every view that can select something.
            "ui": EntityRule(
                categories: ["configuration"],
                changedEvent: "fleetview.ui.changed",
                semantic: [
                    "selectedProject": Semantic(event: "fleetview.ui.project_selected",
                                                fromKey: "project.from", toKey: "project.to"),
                    "highlightedTerminal": Semantic(event: "fleetview.ui.task_selected",
                                                    fromKey: "selection.from", toKey: "selection.to"),
                    "highlightedCluster": Semantic(event: "fleetview.ui.cluster_selected",
                                                   fromKey: "selection.from", toKey: "selection.to"),
                ]),
        ],
        fallback: EntityRule(categories: ["configuration"], changedEvent: "fleetview.state.changed"))
}
