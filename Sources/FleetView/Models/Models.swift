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
        case .working:  return "working"
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
