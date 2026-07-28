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

        PanelVersions.shared.load()
        WebAudit.shared.start(auditor: auditor)

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
        WebAudit.shared.stop()
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

    // Per-terminal turn accounting, so a finished turn can report how long it took and how many
    // tokens it cost without the log carrying a running total on every event.
    private var turnStart: [UUID: Date] = [:]
    private var turnStartTokens: [UUID: Int] = [:]

    func beginTurn(_ id: UUID, tokens: Int) {
        turnStart[id] = Date()
        turnStartTokens[id] = tokens
    }

    func endTurn(_ id: UUID, tokens: Int) -> (duration: TimeInterval?, delta: Int) {
        let started = turnStart.removeValue(forKey: id)
        let before = turnStartTokens.removeValue(forKey: id)
        return (started.map { Date().timeIntervalSince($0) }, max(0, tokens - (before ?? tokens)))
    }

    // Panel authorship. A `PreToolUse` hook that names panel.html identifies the writer exactly;
    // signals are kept briefly because the file lands a moment after the tool call is announced.
    private static let panelSignalWindow: TimeInterval = 120
    private var panelSignals: [PanelWriteSignal] = []

    func notePanelWrite(_ signal: PanelWriteSignal) {
        panelSignals.append(signal)
        let cutoff = Date().addingTimeInterval(-Self.panelSignalWindow)
        panelSignals.removeAll { $0.at < cutoff }
    }

    func panelAttribution(active: [PanelWriteSignal], at moment: Date) -> PanelAttribution {
        PanelAttributionResolver.resolve(signals: panelSignals, active: active, at: moment)
    }
}

// MARK: - Pipeline taps: agent hooks and shell commands

extension AppState {
    /// The actor a hook event belongs to: the agent for its own lifecycle, the shell for commands
    /// typed at the prompt.
    func hookActor(_ ev: EventWatcher.Event, terminal: TerminalSession) -> AuditActor {
        if ev.event.hasPrefix("ShellCommand") {
            return AuditActor(kind: .shell, name: terminal.name, userName: NSUserName())
        }
        let kind = terminal.agentKind == .unknown ? nil : terminal.agentKind.rawValue
        return AuditActor(kind: .agent,
                          id: ev.sessionId ?? terminal.sessionId,
                          name: terminal.name,
                          agentKind: kind)
    }

    /// Turn a hook event into audit records.
    ///
    /// Conversation content is never copied here: a prompt is logged as a length, a digest, a short
    /// preview and a pointer to the transcript that holds the real thing. Tool calls are not logged
    /// at all — the transcript already has every one of them — except that a tool writing the panel
    /// is remembered, so the archive can say which conversation produced it.
    func auditHookEvent(_ ev: EventWatcher.Event, terminal id: UUID) {
        guard let t = terminals.first(where: { $0.id == id }) else { return }
        let config = AuditConfig.current
        let target = auditTarget(terminal: id)

        switch ev.event {
        case "SessionStart":
            audit.emit("fleetview.agent.session_started",
                       categories: ["session"],
                       message: "\(t.agentKind.rawValue) session \(ev.source ?? "started")",
                       target: target,
                       data: AuditValue.compact([
                        "source": ev.source.map { .string($0) },
                        "agent.session.id": ev.sessionId.map { .string($0) },
                        "transcript.path": ev.transcriptPath.map { .string($0) },
                       ]))

        case "UserPromptSubmit":
            let prompt = ev.prompt ?? ""
            AppAudit.shared.beginTurn(id, tokens: t.newTokens)
            var data = AuditValue.compact([
                "prompt.chars": .int(prompt.count),
                "prompt.lines": .int(prompt.split(separator: "\n", omittingEmptySubsequences: false).count),
                "prompt.sha256": .string(AuditDigest.short(prompt)),
                "agent.session.id": (ev.sessionId ?? t.sessionId).map { .string($0) },
                // The body stays where it already lives; this is the pointer to it.
                "transcript.path": (ev.transcriptPath ?? t.transcriptPath).map { .string($0) },
            ])
            if config.promptPreview, !prompt.isEmpty {
                data["prompt.preview"] = .string(String(prompt.prefix(config.promptPreviewChars))
                    .replacingOccurrences(of: "\n", with: " "))
            }
            audit.emit("fleetview.agent.prompt_submitted",
                       categories: ["session"],
                       message: "prompt submitted (\(prompt.count) chars) — body in transcript",
                       target: target, data: data)

        case "PermissionRequest":
            audit.emit("fleetview.agent.permission_requested",
                       categories: ["session"],
                       message: "waiting for approval",
                       target: target,
                       data: AuditValue.compact(["source": .string("permission_request"),
                                                 "message": ev.message.map { .string($0) }]))

        case "Notification":
            let msg = (ev.message ?? "").lowercased()
            guard msg.contains("permission") || msg.contains("approve")
                    || msg.contains("approval") || msg.contains("confirm") else { break }
            audit.emit("fleetview.agent.permission_requested",
                       categories: ["session"],
                       message: ev.message ?? "waiting for approval",
                       target: target,
                       data: AuditValue.compact(["source": .string("notification"),
                                                 "message": ev.message.map { .string($0) }]))

        case "Stop":
            // Token deltas are FleetView's own accounting, summarised once per turn rather than
            // repeated on every event.
            let turn = AppAudit.shared.endTurn(id, tokens: t.newTokens)
            audit.emit(AuditEvent(name: "fleetview.agent.turn_finished",
                                  categories: ["session"],
                                  message: "turn finished (+\(turn.delta) new tokens)",
                                  target: target,
                                  data: AuditValue.compact([
                                    "tokens.delta": .int(turn.delta),
                                    "tokens.new_total": .int(t.newTokens),
                                    "agent.session.id": t.sessionId.map { .string($0) },
                                  ]),
                                  durationNanos: turn.duration.map { Int($0 * 1_000_000_000) }))

        case "PreToolUse":
            guard ev.writesPanel else { break }
            AppAudit.shared.notePanelWrite(PanelWriteSignal(
                terminalID: id.uuidString, terminalName: t.name,
                agentKind: t.agentKind == .unknown ? nil : t.agentKind.rawValue,
                sessionID: ev.sessionId ?? t.sessionId,
                transcriptPath: ev.transcriptPath ?? t.transcriptPath,
                tool: ev.toolName, at: Date()))

        case "ShellCommand":
            guard config.shellCommand != "off", let raw = ev.command, !raw.isEmpty else { break }
            let argv0 = raw.split(separator: " ").first.map(String.init) ?? raw
            let redacted = AppAudit.shared.redact(raw)
            let line = config.shellCommand == "argv0" ? argv0 : redacted.text
            audit.emit(AuditEvent(name: "fleetview.shell.command_started",
                                  categories: ["process"], types: ["start"],
                                  message: "$ \(line)",
                                  target: target,
                                  data: AuditValue.compact([
                                    "cmd.id": ev.cmdId.map { .string($0) },
                                    "cmd.line": .string(line),
                                    "cmd.argv0": .string(argv0),
                                    "cmd.cwd": .string(ev.cwd ?? t.cwd),
                                    "cmd.shell": .string("zsh"),
                                    "cmd.pid": ev.pid.map { .int($0) },
                                    "cmd.tty": ev.tty.map { .string($0) },
                                    "cmd.redacted": redacted.redacted ? .bool(true) : nil,
                                  ])))

        case "ShellCommandDone":
            guard config.shellCommand != "off", let cmdId = ev.cmdId else { break }
            let code = ev.exitCode ?? 0
            audit.emit(AuditEvent(name: "fleetview.shell.command_finished",
                                  categories: ["process"], types: ["end"],
                                  outcome: code == 0 ? .success : .failure,
                                  message: "exited \(code)"
                                         + (ev.durationMs.map { " in \($0) ms" } ?? ""),
                                  target: target,
                                  data: AuditValue.compact([
                                    "cmd.id": .string(cmdId),
                                    "cmd.exit_code": .int(code),
                                    "cmd.duration_ms": ev.durationMs.map { .int($0) },
                                  ]),
                                  durationNanos: ev.durationMs.map { $0 * 1_000_000 }))

        default:
            break
        }
    }

    /// Terminals that could plausibly have written a panel just now, for attribution tier 2.
    func panelWriteCandidates() -> [PanelWriteSignal] {
        terminals.filter { $0.status == .working }.map { t in
            PanelWriteSignal(terminalID: t.id.uuidString, terminalName: t.name,
                             agentKind: t.agentKind == .unknown ? nil : t.agentKind.rawValue,
                             sessionID: t.sessionId,
                             transcriptPath: t.transcriptPath,
                             at: t.lastActivity ?? Date())
        }
    }
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
