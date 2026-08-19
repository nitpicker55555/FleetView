import Foundation

enum TermStatus: String, Codable {
    case closed    // no live window/process
    case shell     // window open, plain shell — no Claude session detected (non-agent work)
    case idle      // Claude session active, waiting for input
    case working   // Claude actively working
    case needsYou  // Claude needs attention (permission / notification)
    case exited    // process ended

    var label: String {
        switch self {
        case .closed:   return "closed"
        case .shell:    return "shell"
        case .idle:     return "idle"
        case .working:  return "running"
        case .needsYou: return "needs you"
        case .exited:   return "exited"
        }
    }

    /// Window/process is open (used to choose raise vs reopen).
    var isOpen: Bool { self == .shell || self == .idle || self == .working || self == .needsYou }

    /// A Claude agent session is (or was) active in this terminal.
    var isAgent: Bool { self == .idle || self == .working || self == .needsYou }

    /// Task-oriented label for the sidebar: is the agent running, or has it returned a result?
    var taskLabel: String {
        switch self {
        case .working:  return "running"
        case .idle:     return "returned"
        case .needsYou: return "needs you"
        case .shell:    return "shell"
        case .exited:   return "exited"
        case .closed:   return "closed"
        }
    }
}

/// Which agent CLI a terminal is running — drives a subtle colour cue on the card.
enum AgentKind: String, Codable {
    case unknown, claude, codex
    var label: String { self == .unknown ? "" : rawValue }
}

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var isGit: Bool = false
}

/// A terminal that used to be on the board, kept after its card was removed.
///
/// Removing a card destroys the tmux session, and until now it also destroyed the only record that
/// the conversation existed: the name it was called, the uuid other machines addressed it by, and
/// the agent session that holds the transcript. The work outlives the card, so the address of it
/// should too — this is what the project's history drawer lists, and what a restore resumes from.
struct TerminalArchive: Identifiable, Codable, Hashable {
    /// The terminal's own uuid, not a fresh one: this row *is* that terminal, and the uuid is the
    /// thing you came looking for (it is what `project-manager` and a card's `ip/uuid` address).
    var id: UUID
    var projectId: UUID
    /// The project's folder. Kept alongside the id because the id does not survive the project
    /// being closed and reopened — `addProject` mints a fresh one for the same folder, and every
    /// archived row would suddenly belong to a project that no longer exists. The path is what
    /// stayed the same, so the path is what the lookup uses.
    /// Optional, not defaulted: a synthesised decoder treats a missing key as an error even when
    /// the property has a default, so a non-optional here would make every row written before it
    /// existed undecodable.
    var projectPath: String?
    var name: String
    var cwd: String
    var agentKind: AgentKind = .unknown
    /// The agent session id and its transcript, when the terminal ever started one. Both nil for a
    /// card that only ever held a shell — there is nothing to resume and the drawer says so.
    var sessionId: String?
    var transcriptPath: String?
    var newTokens: Int = 0
    var lastPrompt: String = ""
    var removedAt: Date
}

struct TerminalSession: Identifiable, Codable, Hashable {
    var id = UUID()
    var projectId: UUID
    var name: String
    var clusterId: UUID?
    var cwd: String
    var autoRunClaude: Bool = true
    var subtaskDone: Bool = false

    // Live-ish fields (persisted as last-known; reset on load).
    var status: TermStatus = .closed
    var agentKind: AgentKind = .unknown
    var lastPrompt: String = ""
    var sessionId: String?
    var transcriptPath: String?

    /// Cumulative "new" tokens for this session (input + cache-writes + output, excluding cache reads).
    /// Persisted for an instant badge on launch; the transcript on disk is the real source of truth.
    var newTokens: Int = 0

    /// When this terminal last had *real* activity — a prompt, tool call, agent reply, shell command,
    /// interrupt, or remote keystroke. NOT bumped by merely opening/raising the window. Persisted so
    /// "3m ago" survives a relaunch. `nil` until the first interaction.
    var lastActivity: Date? = nil

    /// When the current run started — what the card counts up from while the agent is working.
    /// Only ever set/cleared by `AppState.enterStatus`, which is the single door every status change
    /// goes through: a stray `status = .working` elsewhere is a stopwatch that never starts, and a
    /// stray `status = .idle` is one that never stops. Not restored on launch (see `load`), because
    /// a run that outlived FleetView is not one this clock can honestly measure.
    var runningSince: Date? = nil

    /// How long the last finished run took. It stays on the card (dimmed) once the run ends rather
    /// than blanking: "that took 6:12" is the answer you come back to the board for, and it is the
    /// one thing a transcript never records — it says what happened, never how long it took. The
    /// next run replaces it.
    var lastRunSeconds: Int? = nil
}

struct Cluster: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
}

/// A free-form text note kept in the sidebar's "NOTES" section.
struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
}

/// One point on a project's "new tokens over time" curve (cumulative, monotonic).
struct TokenSample: Hashable {
    var t: Date
    var newTokens: Int
}

/// A unit of work shown in the sidebar: either a standalone terminal or a whole cluster.
/// Holds ids only — the row looks up live state so renames/status reflect immediately.
enum TaskItem: Identifiable {
    case terminal(UUID)
    case cluster(UUID)

    var id: String {
        switch self {
        case .terminal(let u): return "t-\(u.uuidString)"
        case .cluster(let u):  return "c-\(u.uuidString)"
        }
    }
}

/// Tasks grouped under their project (for the sidebar's per-project separation).
struct TaskGroup: Identifiable {
    let project: Project
    let tasks: [TaskItem]
    var id: UUID { project.id }
}
