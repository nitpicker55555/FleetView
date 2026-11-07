import SwiftUI
import AppKit

/// The palette, the type scale and the shapes — Material 3, generated rather than chosen.
///
/// Every colour below comes out of Material's `SchemeTonalSpot` for one seed colour (#6750A4 unless
/// the user picked another — FleetView → 配色…), computed by `MaterialScheme`. They are not
/// hand-tuned on purpose: the previous palette was, and it drifted into a Claude orange 11° from the
/// "needs you" amber, a Codex teal identical to the shell status in light mode, and an accent used
/// for a dozen unrelated things. Change the seed rather than nudging one value. DESIGN.md (kept
/// with the redesign mockups) is the reference for which role is used where.
///
/// Every colour is a dynamic `NSColor`, so the system resolves it per appearance: nothing observes
/// the appearance and no view can be left holding a stale colour. The seed is the other axis, and
/// that one is observed — see `ThemeStore`. The web dashboard and the file window's editor are
/// handed the same values (`ThemeStore.css`, `EditorBridge.colors`).
enum Theme {

    /// A colour with a value per appearance, each `0xRRGGBB`. `ThemeStore` builds every role with it.
    static func dual(_ dark: UInt32, _ light: UInt32,
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

    private static func role(_ r: MaterialScheme.Role) -> Color { ThemeStore.shared.colors[r.rawValue] }

    // MARK: Material 3 roles (SchemeTonalSpot, from the current seed)

    static var primary: Color                 { role(.primary) }
    static var onPrimary: Color               { role(.onPrimary) }
    static var primaryContainer: Color        { role(.primaryContainer) }
    static var onPrimaryContainer: Color      { role(.onPrimaryContainer) }
    static var secondaryContainer: Color      { role(.secondaryContainer) }
    static var onSecondaryContainer: Color    { role(.onSecondaryContainer) }
    static var tertiary: Color                { role(.tertiary) }
    static var tertiaryContainer: Color       { role(.tertiaryContainer) }
    static var onTertiaryContainer: Color     { role(.onTertiaryContainer) }
    static var surface: Color                 { role(.surface) }
    static var surfaceContainerLow: Color     { role(.surfaceContainerLow) }
    static var surfaceContainer: Color        { role(.surfaceContainer) }
    static var surfaceContainerHigh: Color    { role(.surfaceContainerHigh) }
    static var surfaceContainerHighest: Color { role(.surfaceContainerHighest) }
    static var onSurface: Color               { role(.onSurface) }
    static var onSurfaceVariant: Color        { role(.onSurfaceVariant) }
    static var outline: Color                 { role(.outline) }
    static var outlineVariant: Color          { role(.outlineVariant) }
    static var inverseSurface: Color          { role(.inverseSurface) }
    static var inverseOnSurface: Color        { role(.inverseOnSurface) }
    static var error: Color                   { role(.error) }
    static var errorContainer: Color          { role(.errorContainer) }
    static var onErrorContainer: Color        { role(.onErrorContainer) }

    // A running card. Just started is the light tone and settled the deep one in both appearances —
    // M3's fixed tone 80 for the first ten seconds, then tone 30 (dark) / 40 (light). The plain
    // roles would flip it: in light mode `primary` is the deep tone and its container the pale one,
    // so the fresh card came out darker than the settled ones, the reverse of the dark board.
    static var runFresh: Color                { role(.runFresh) }
    static var onRunFresh: Color              { role(.onRunFresh) }
    static var runSettled: Color              { role(.runSettled) }
    static var onRunSettled: Color            { role(.onRunSettled) }

    // "Needs you". Material has no warning role, so this is what M3 does with a custom colour:
    // #E0A100 harmonised toward the seed, then taken at tones 80/40 (colour) and 30/90 (container).
    static var warn: Color                    { role(.warn) }
    static var warnContainer: Color           { role(.warnContainer) }
    static var onWarnContainer: Color         { role(.onWarnContainer) }

    /// Content that is shown but not live — an exited or closed terminal. M3's disabled opacity.
    static let endedOpacity: Double = 0.38

    // MARK: The names the views use

    // Surfaces, darkest to lightest in dark mode: the board, the panels on it, the cards on those.
    static var bg: Color        { surface }
    static var panel: Color     { surfaceContainerLow }
    static var card: Color      { surfaceContainerHigh }
    static var cardHover: Color { surfaceContainerHighest }
    /// Hairlines and dividers.
    static var stroke: Color    { outlineVariant }
    static var text: Color      { onSurface }
    static var subtext: Color   { onSurfaceVariant }
    /// Selection, focus, the path you are on, a running agent. Nothing decorative.
    static var accent: Color    { primary }
    /// Foreground for content sitting ON `accent`.
    static var onAccent: Color  { onPrimary }
    /// A marked (bookmarked) card. Identity, not state: a glyph only, never the card's fill.
    static var markTint: Color  { tertiary }
    static var markCard: Color  { surfaceContainerHigh }
    /// Positive feedback ("copied", tokens still flowing). The scheme has no green and does not need
    /// one: the accent already means "live".
    static var green: Color     { primary }
    static var amber: Color     { warn }
    static var red: Color       { error }

    // Agent identity: a small mark at the foot of a card, never a border or a fill. Codex is
    // monochrome, like its own mark — which also keeps it clear of every status colour.
    static let claudeTint = dual(0xD97757, 0xB4552F)
    static var codexTint: Color { onSurface }

    static func agentColor(_ k: AgentKind) -> Color {
        switch k {
        case .claude:  return claudeTint
        case .codex:   return codexTint
        case .unknown: return subtext
        }
    }

    /// Session-tree lanes. The path you are on is the accent; every abandoned branch is the same
    /// neutral grey. They used to take a palette colour each — teal, orange, violet, green, amber —
    /// which put the status colours on lines that have no status, and made a tree with three
    /// branches the loudest thing in the window.
    static func laneColor(_ index: Int) -> Color { index < 0 ? accent : outline }

    static func statusColor(_ s: TermStatus) -> Color {
        switch s {
        case .working:  return primary
        case .needsYou: return warn
        case .idle:     return outline
        case .shell:    return outline
        case .exited:   return onSurface.opacity(endedOpacity)
        case .closed:   return onSurface.opacity(endedOpacity)
        }
    }

    // MARK: Shapes and sizes

    enum Radius {
        static let chip: CGFloat = 8
        static let card: CGFloat = 12
        static let sheet: CGFloat = 16
        static let dialog: CGFloat = 28
    }

    /// Every control that sits in a bar is this tall, and either all of a bar's controls have a
    /// container or none do.
    static let controlHeight: CGFloat = 36
}

/// The Material 3 type scale, set in the system font. Six sizes and three weights; anything that
/// is not one of these is a mistake, not a style.
extension Font {
    /// 16/24 medium — project names, panel titles.
    static let fvTitleMedium = Font.system(size: 16, weight: .medium)
    /// 14/20 medium — card names, section titles.
    static let fvTitleSmall  = Font.system(size: 14, weight: .medium)
    /// 14/20 — sidebar rows, tree prompts, fields.
    static let fvBody        = Font.system(size: 14)
    /// 12/16 — a card's last prompt, reply previews, secondary text.
    static let fvBodySmall   = Font.system(size: 12)
    /// 12/16 medium — timers, badges, buttons, chips.
    static let fvLabel       = Font.system(size: 12, weight: .medium)
    /// 11/16 medium — group names, token counts, metadata.
    static let fvLabelSmall  = Font.system(size: 11, weight: .medium)
    /// Ids, paths, commands.
    static let fvMono        = Font.system(size: 11, design: .monospaced)
    static let fvMonoBody    = Font.system(size: 12, design: .monospaced)
}
