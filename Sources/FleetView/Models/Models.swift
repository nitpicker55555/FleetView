import Foundation

enum TermStatus: String, Codable {
    case closed    // no live window/process
    case idle      // window open, agent waiting for input
    case working   // agent actively working
    case needsYou  // agent needs attention (permission / notification)
    case exited    // process ended

    var label: String {
        switch self {
        case .closed:   return "closed"
        case .idle:     return "idle"
        case .working:  return "working"
        case .needsYou: return "needs you"
        case .exited:   return "exited"
        }
    }

    var isLive: Bool { self == .idle || self == .working || self == .needsYou }
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
