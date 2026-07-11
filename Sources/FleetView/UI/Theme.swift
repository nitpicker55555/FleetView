import SwiftUI

/// A restrained dark palette matching the user's Claude dark theme.
enum Theme {
    static let bg        = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let panel     = Color(red: 0.11, green: 0.12, blue: 0.145)
    static let card      = Color(red: 0.145, green: 0.155, blue: 0.185)
    static let cardHover = Color(red: 0.18, green: 0.19, blue: 0.225)
    static let stroke    = Color.white.opacity(0.07)
    static let text      = Color(red: 0.92, green: 0.93, blue: 0.95)
    static let subtext   = Color(red: 0.60, green: 0.63, blue: 0.69)
    static let accent    = Color(red: 0.47, green: 0.62, blue: 1.0)

    // "subtask done" card styling — a clear green shift.
    static let doneCard   = Color(red: 0.10, green: 0.17, blue: 0.13)
    static let doneStroke = Color(red: 0.36, green: 0.82, blue: 0.55)
    static let green      = Color(red: 0.36, green: 0.82, blue: 0.55)

    static func statusColor(_ s: TermStatus) -> Color {
        switch s {
        case .working:  return Color(red: 0.36, green: 0.82, blue: 0.55)   // green
        case .shell:    return Color(red: 0.30, green: 0.68, blue: 0.76)   // teal — plain shell
        case .idle:     return Color(red: 0.55, green: 0.58, blue: 0.64)   // gray — agent idle
        case .needsYou: return Color(red: 0.98, green: 0.72, blue: 0.32)   // amber
        case .exited:   return Color(red: 0.85, green: 0.42, blue: 0.45)   // red
        case .closed:   return Color.white.opacity(0.22)
        }
    }
}
