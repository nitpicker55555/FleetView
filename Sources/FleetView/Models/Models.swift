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
    var lastPrompt: String = ""
    var sessionId: String?
    var transcriptPath: String?
}

struct Cluster: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
}
