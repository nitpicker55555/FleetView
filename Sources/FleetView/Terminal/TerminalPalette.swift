import AppKit
import SwiftTerm

/// The colours a terminal window draws with, in two appearances.
///
/// `Theme` gets to hand SwiftUI one dynamic `NSColor` per role and let the system resolve it per
/// appearance. That trick does not work here: SwiftTerm flattens every colour the moment it is
/// assigned (`NSColor.getTerminalColor()`, `caretColor.cgColor`), so a dynamic colour would freeze
/// at whichever appearance was current when the window opened and never move again. The palette is
/// therefore two flat sets, re-applied by hand on each flip — see
/// `TerminalWindowController.applyAppearance()`.
struct TerminalPalette {
    let background: NSColor
    let foreground: NSColor
    /// The 16 ANSI colours, 8 normal then 8 bright. SwiftTerm derives the whole 256-colour cube from
    /// these plus fg/bg (`Ansi256PaletteStrategy.base16Lab`, its default), so installing these is
    /// also what makes 256-colour output follow the appearance instead of staying tuned for black.
    let ansi: [SwiftTerm.Color]

    static func matching(_ appearance: NSAppearance) -> TerminalPalette {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }

    /// Dark is SwiftTerm's own defaults, value for value — Apple Terminal's palette on black. The
    /// ask was for the window to gain a *light* appearance, not to have its dark one redesigned, so
    /// nothing here moves a pixel from what this window has always looked like.
    ///
    /// They have to be spelled out because `Color.terminalAppColors` and `Color.defaultForeground`
    /// are internal to SwiftTerm: once light has been installed over the defaults there is no way to
    /// ask for them back.
    static let dark = TerminalPalette(
        background: rgb(0x000000),
        // `Color.defaultForeground` is 35389/65535 grey, which is not any whole 8-bit value —
        // written as the fraction so it stays the exact grey rather than drifting to #8A8A8A.
        foreground: NSColor(srgbRed: 35389.0 / 65535, green: 35389.0 / 65535,
                            blue: 35389.0 / 65535, alpha: 1),
        ansi: ansi([0x000000, 0xC23621, 0x25BC24, 0xADAD27, 0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
                    0x818383, 0xFC391F, 0x31E722, 0xEAEC23, 0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB]))

    /// Light is GitHub Primer light, the same source `Theme`'s light column comes from, so a
    /// terminal window and the board behind it are the same two colours. Its `fg.default #1F2328`
    /// on white is `Theme.text`/`Theme.card` exactly.
    ///
    /// A light ANSI set is not the dark one lightened: on white, a colour has to get *darker* to
    /// stay legible, and the "bright" half — which `useBrightColors` also hands every bold run —
    /// can no longer be the louder half or bold text would be the least readable thing on screen.
    /// Primer's ordering handles both: bright is a shade off the normal colour, not a neon one, and
    /// white/bright-white are greys (#6E7781/#8C959F) because white-on-white is nothing at all.
    static let light = TerminalPalette(
        background: rgb(0xFFFFFF),
        foreground: rgb(0x1F2328),
        ansi: ansi([0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
                    0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F]))

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255, alpha: 1)
    }

    /// 8-bit channels widened to SwiftTerm's 16-bit ones. ×257, not ×256: it maps 0xFF to 0xFFFF
    /// rather than 0xFF00, so white stays white.
    private static func ansi(_ hexes: [UInt32]) -> [SwiftTerm.Color] {
        hexes.map { hex in
            SwiftTerm.Color(red: UInt16(((hex >> 16) & 0xFF) * 257),
                            green: UInt16(((hex >> 8) & 0xFF) * 257),
                            blue: UInt16((hex & 0xFF) * 257))
        }
    }
}
