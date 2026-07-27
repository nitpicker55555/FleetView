import AppKit
import Combine
import FleetViewAudit

/// Connects FleetView's state to the audit log.
///
/// The whole point of this file is that it is the *only* place the app has to know about logging.
/// Views never call it. Adding a button, a web endpoint, a context-menu item or a field on
/// `TerminalSession` requires no change here: state changes are detected by diffing, and the actor
/// is whatever the ambient `AuditContext` says.
///
/// Two paths reach the log:
///
///  * `AppState.audited(_:_:)` wraps a model operation, so the record carries the *intent*
///    ("terminal.rename") as well as the resulting diff — and produces a record even when nothing
///    changed, which is how raises, keystrokes and failed requests stay visible.
///  * a debounced observer on `objectWillChange` sweeps up every other mutation, including ones
///    from code paths nobody remembered to wrap.
///
/// Both share one baseline snapshot, so a change is reported exactly once.
@MainActor
final class AppAudit {
    static let shared = AppAudit()

    private(set) var auditor: Auditor = .disabled
    private var baseline = AuditSnapshot()
    private var observer: AnyCancellable?
    private var sweepScheduled = false
    private let redaction = Redaction()

    /// How long to wait before sweeping up unwrapped changes. Long enough that a burst of
    /// `@Published` writes inside one operation collapses into one diff, short enough that the log
    /// still reads as a live sequence.
    private let sweepDelay: TimeInterval = 0.25

    private init() {}

    // MARK: - Lifecycle

    func start(_ state: AppState) {
        FV.ensureSupportDir()
        let resource = AuditResource(serviceVersion: FV.version,
                                     instanceID: Identifiers.shortRandom())
        auditor = Auditor(sink: FileAuditSink(directory: FV.logsDir, resource: resource))

        // Anything with no explicit context is a person at the Mac. This one line is what lets
        // every present and future SwiftUI action be attributed without touching a view.
        AuditContext.fallback = AuditActor(kind: .desktop, userName: NSUserName())

        baseline = state.auditSnapshot()
        auditor.emit("fleetview.app.started",
                     categories: ["configuration"],
                     message: "FleetView \(FV.version) started",
                     data: [
                        "projects": .int(state.projects.count),
                        "terminals": .int(state.terminals.count),
                        "clusters": .int(state.clusters.count),
                        "instance": .string(resource.instanceID),
                     ])

        observer = state.objectWillChange.sink { [weak self, weak state] _ in
            guard let self, let state else { return }
            self.scheduleSweep(state)
        }
    }

    func stop(reason: String) {
        auditor.emit("fleetview.app.stopped",
                     categories: ["configuration"],
                     message: "FleetView stopping (\(reason))",
                     data: ["reason": .string(reason)])
        auditor.flush()
        observer = nil
    }

    // MARK: - Diffing

    /// Emit everything that changed since the last flush. `intent` names the operation responsible,
    /// when one declared itself.
    func flush(_ state: AppState, intent: AuditIntent? = nil) {
        let now = state.auditSnapshot()
        auditor.record(from: baseline, to: now, intent: intent)
        baseline = now
    }

    private func scheduleSweep(_ state: AppState) {
        guard !sweepScheduled else { return }
        sweepScheduled = true
        // `objectWillChange` fires *before* the mutation lands, so the sweep has to happen on a
        // later turn of the run loop to observe the new value.
        DispatchQueue.main.asyncAfter(deadline: .now() + sweepDelay) { [weak self, weak state] in
            self?.sweepScheduled = false
            guard let self, let state else { return }
            self.flush(state)
        }
    }

    // MARK: - Helpers used by the pipeline taps

    /// Shell command lines go through here before they are logged.
    func redact(_ text: String) -> (text: String, redacted: Bool) { redaction.apply(to: text) }
}

// MARK: - Projection

extension AppState {
    var audit: Auditor { AppAudit.shared.auditor }

    /// Run a model operation as an audited unit of work.
    ///
    /// Wrapping happens here, at the model layer — never in a view. A new UI that calls
    /// `state.removeTerminal(id)` inherits the audit trail of the old one for free.
    @discardableResult
    func audited<T>(_ intent: AuditIntent, _ body: () -> T) -> T {
        let result = body()
        AppAudit.shared.flush(self, intent: intent)
        return result
    }

    /// Everything worth auditing, as of right now.
    ///
    /// Fields come from encoding the models themselves rather than from a hand-written list, so a
    /// property added to `TerminalSession` is audited the moment it exists — as
    /// `fleetview.terminal.changed` if nobody has classified it, which is the point.
    func auditSnapshot() -> AuditSnapshot {
        var entities: [AuditEntity] = []

        for project in projects {
            entities.append(AuditEntity(kind: "project",
                                        id: project.id.uuidString,
                                        label: project.name,
                                        fields: AuditValue.fields(of: project, dropping: ["id"])))
        }

        for cluster in clusters {
            entities.append(AuditEntity(kind: "cluster",
                                        id: cluster.id.uuidString,
                                        label: cluster.name,
                                        fields: AuditValue.fields(of: cluster, dropping: ["id"]),
                                        context: ["cluster.members": .int(members(ofCluster: cluster.id).count)]))
        }

        for terminal in terminals {
            let project = projects.first { $0.id == terminal.projectId }
            let cluster = clusters.first { $0.id == terminal.clusterId }
            entities.append(AuditEntity(
                kind: "terminal",
                id: terminal.id.uuidString,
                label: terminal.name,
                fields: AuditValue.fields(of: terminal, dropping: ["id"]),
                // Repeated onto every event about this terminal so one log line answers
                // "which project, which cluster" without a join.
                context: AuditValue.compact([
                    "terminal.cwd": .string(terminal.cwd),
                    "terminal.agent": terminal.agentKind == .unknown ? nil : .string(terminal.agentKind.rawValue),
                    "cluster.id": cluster.map { .string($0.id.uuidString) },
                    "cluster.name": cluster.map { .string($0.name) },
                    "project.id": project.map { .string($0.id.uuidString) },
                    "project.name": project.map { .string($0.name) },
                ])))
        }

        for note in notes {
            entities.append(AuditEntity(kind: "note",
                                        id: note.id.uuidString,
                                        label: String(note.text.prefix(40)),
                                        fields: AuditValue.fields(of: note, dropping: ["id"])))
        }

        // Selection modelled as state, so "what is the user looking at" is diffed like everything
        // else and a click needs no logging code in the view that handles it.
        entities.append(AuditEntity(kind: "ui", id: "app", label: "selection",
                                    fields: AuditValue.compact([
                                        "selectedProject": selectedProjectId.map { .string($0.uuidString) },
                                        "highlightedTerminal": highlightedTerminalId.map { .string($0.uuidString) },
                                        "highlightedCluster": highlightedClusterId.map { .string($0.uuidString) },
                                    ])))

        return AuditSnapshot(entities)
    }

    /// Target descriptor for a terminal, for events that are not state changes (raises, keystrokes,
    /// failures) and so have no diffed entity to borrow one from.
    func auditTarget(terminal id: UUID) -> AuditTarget {
        guard let t = terminals.first(where: { $0.id == id }) else {
            return AuditTarget(kind: "terminal", id: id.uuidString)
        }
        let project = projects.first { $0.id == t.projectId }
        let cluster = clusters.first { $0.id == t.clusterId }
        return AuditTarget(kind: "terminal", id: t.id.uuidString, name: t.name,
                           fields: AuditValue.compact([
                            "terminal.cwd": .string(t.cwd),
                            "terminal.status": .string(t.status.rawValue),
                            "cluster.name": cluster.map { .string($0.name) },
                            "project.name": project.map { .string($0.name) },
                           ]))
    }
}
