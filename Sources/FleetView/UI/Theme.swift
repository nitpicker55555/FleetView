import SwiftUI
import AppKit

/// A restrained palette in two appearances, following the system.
///
/// Every colour is a dynamic `NSColor`, so the system resolves it per appearance: the ~340
/// `Theme.x` call sites needed no changes, there is nothing to observe or invalidate, and no view
/// can be left holding a stale colour. Keeping both values on one line is also the only way a pair
/// like `card`/`cardHover` stays coherent.
///
/// Written as hex because the web dashboard's CSS variables are the same palette — the dark column
/// below is `:root` in WebDashboardPage verbatim, so the two can be compared by eye.
///
/// The light column is **GitHub Primer light**, which is tuned for exactly this kind of dense,
/// text-heavy tool UI and whose semantic colours land on the status dots already in use:
/// `fg.default #1f2328`, `fg.muted #59636e`, `border.default #d1d9e0`, `accent.fg #0969da`,
/// `success.fg #1a7f37`, `attention.fg #9a6700`, `danger.fg #d1242f`.
enum Theme {

    /// A colour with a value per appearance, each `0xRRGGBB`. Alpha is per side because the two
    /// appearances do not always agree on it: a hairline is a translucent wash over dark and a
    /// solid line over light.
    private static func dual(_ dark: UInt32, _ light: UInt32,
                             darkAlpha: Double = 1, lightAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                           green: Double((hex >> 8) & 0xFF) / 255,
                           blue: Double(hex & 0xFF) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    /// True when the app is currently drawing dark. Also what the web dashboard is told so it can
    /// match the desktop rather than the phone (see `WebSnapshot.dark`).
    @MainActor static var isDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // Surfaces. The dark theme stacks board → panel → card from darkest to lightest, so light
    // inverts the stack rather than the hues: a grey board, a near-white panel, and white cards
    // that sit clearly on top of both. A pure-white board would leave the cards nowhere to go.
    static let bg        = dual(0x14171C, 0xEEF1F5)
    static let panel     = dual(0x1C1F25, 0xF7F8FA)
    static let card      = dual(0x25282F, 0xFFFFFF)
    static let cardHover = dual(0x2E3039, 0xF1F3F6)
    // A hairline is a wash of the opposite end: a light film over dark. Primer's border.default is
    // already a solid colour, so light needs no transparency at all.
    static let stroke    = dual(0xFFFFFF, 0xD1D9E0, darkAlpha: 0.07)
    static let text      = dual(0xEBEDF2, 0x1F2328)
    static let subtext   = dual(0x99A1B0, 0x59636E)
    // The dark blue is built to glow on near-black and reads washed out on white; Primer's accent
    // is built the other way round. Both carry `onAccent`, never a hard-coded black or white.
    static let accent    = dual(0x7A9EFF, 0x0969DA)

    /// Foreground for content sitting ON `accent` or another saturated fill. Hard-coding black here
    /// is what makes a filled button unreadable in one appearance or the other.
    static let onAccent  = dual(0x0B1020, 0xFFFFFF)

    // "subtask done" card styling — a clear green shift.
    static let doneCard   = dual(0x1A2B21, 0xDAFBE1)      // light: Primer success.subtle
    static let doneStroke = dual(0x5CD18C, 0x1A7F37)
    static let green      = dual(0x5CD18C, 0x1A7F37)      // Primer success.fg
    static let amber      = dual(0xFAB852, 0x9A6700)      // Primer attention.fg
    static let red        = dual(0xD96B73, 0xD1242F)      // Primer danger.fg

    // Agent cues — a warm tone for Claude, a cool teal for Codex, so the two are easy to tell apart.
    static let claudeTint = dual(0xE69459, 0xBC4C00)      // light: Primer severe.fg
    static let codexTint  = dual(0x66CCD9, 0x0E7490)

    static func agentColor(_ k: AgentKind) -> Color {
        switch k {
        case .claude:  return claudeTint
        case .codex:   return codexTint
        case .unknown: return subtext
        }
    }

    // Session-tree branch lanes: the active path is always `accent`; each side branch takes the
    // next palette colour so parallel attempts stay visually distinct (muted, never louder than
    // the active lane).
    static let lanePalette: [Color] = [
        dual(0x66CCD9, 0x0E7490),   // teal
        dual(0xE69459, 0xBC4C00),   // orange
        dual(0xB58FE6, 0x8250DF),   // purple — light: Primer done.fg
        dual(0x5CD18C, 0x1A7F37),   // green
        dual(0xFAB852, 0x9A6700),   // amber
    ]
    static func laneColor(_ index: Int) -> Color {
        index < 0 ? accent : lanePalette[index % lanePalette.count]
    }

    static func statusColor(_ s: TermStatus) -> Color {
        switch s {
        case .working:  return dual(0x5CD18C, 0x1A7F37)   // green
        case .shell:    return dual(0x4DADC2, 0x0E7490)   // teal — plain shell
        case .idle:     return dual(0x8C94A3, 0x6E7781)   // grey — agent idle
        case .needsYou: return dual(0xFAB852, 0x9A6700)   // amber
        case .exited:   return dual(0xD96B73, 0xD1242F)   // red
        case .closed:   return dual(0xFFFFFF, 0x1F2328, darkAlpha: 0.22, lightAlpha: 0.22)
        }
    }
}
