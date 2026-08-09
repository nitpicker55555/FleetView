import Foundation

/// Makes a dark-themed agent readable on a light terminal, by rewriting the colours it asks for on
/// their way in.
///
/// `TerminalPalette` can only reinterpret *indexed* colour — `ESC[38;5;n m` and the sixteen ANSI
/// slots. Claude Code and Codex do not use it. They pick a palette from their own theme setting
/// (Claude's lives in `~/.claude/settings.json`, and it is not ours to flip) and paint it as 24-bit
/// SGR: `ESC[38;2;r;g;b m`, a literal RGB triple no palette can touch. So a window that turns white
/// under a dark-themed agent ends up with near-white text on white — the terminal followed the
/// appearance and its contents did not.
///
/// This sits in the byte stream between the pty and the emulator. A foreground too pale to read on
/// white is inverted in lightness and then walked darker until it actually clears WCAG AA; a dark
/// background fill is inverted into the tint it should have been, so it does not swallow the text
/// now drawn dark on top of it. Colours that already read fine are passed through as asked — this
/// is a rescue, not a re-theme.
///
/// **The stream is byte-identical unless a colour is genuinely rewritten.** Anything that cannot be
/// parsed with certainty — a CSI carrying private or intermediate bytes, a colon-subparameter
/// colour, an unrecognised form — goes through untouched, because the cost of a resync mistake in a
/// terminal stream is not a wrong colour, it is garbage on the screen.
struct TerminalInk {

    /// A CSI cut in half by a read boundary, held until the rest arrives.
    ///
    /// Holding it back loses nothing: a CSI without its final byte draws nothing, so the emulator
    /// would have been sitting on exactly these bytes too. Dropping them, on the other hand, would
    /// orphan the bytes that complete the sequence and print `0m` into the middle of the screen —
    /// which is why `flushPending` exists for the moment this adapter is switched off.
    private var pending: [UInt8] = []

    /// Rewritten colours, keyed by the triple asked for (plus a bit for fg/bg). A TUI repaints the
    /// same handful of colours thousands of times a second; the HSL round-trip runs once each.
    private var memo: [UInt32: UInt32] = [:]

    private static let esc: UInt8 = 0x1B
    private static let leftBracket = UInt8(ascii: "[")
    private static let semicolon = UInt8(ascii: ";")
    private static let finalSGR = UInt8(ascii: "m")

    /// A partial CSI is a handful of bytes. Anything longer is malformed, and hoarding it would
    /// stall the terminal on a stream that is never going to complete the sequence.
    private static let maxPending = 64

    /// Rewrite one read from the pty. Returns nil when the bytes can be fed through unchanged,
    /// which is the overwhelmingly common case — most reads carry no escape sequence at all.
    mutating func adapt(_ slice: ArraySlice<UInt8>) -> [UInt8]? {
        if pending.isEmpty && !slice.contains(Self.esc) { return nil }

        var input = pending
        pending = []
        input.append(contentsOf: slice)

        var out: [UInt8] = []
        out.reserveCapacity(input.count + 16)
        var i = 0
        while i < input.count {
            guard input[i] == Self.esc else {
                out.append(input[i]); i += 1; continue
            }
            guard i + 1 < input.count else {
                pending = Array(input[i...]); break                       // a lone trailing ESC
            }
            guard input[i + 1] == Self.leftBracket else {
                out.append(input[i]); i += 1; continue                    // OSC, ESC-x, anything else
            }
            // CSI = ESC [ <params 0x30…0x3F> <intermediates 0x20…0x2F> <final 0x40…0x7E>. Only the
            // parameter run is scanned: if what follows it is not `m` the whole thing is copied
            // verbatim, so mis-reading a sequence with intermediate bytes costs nothing.
            var j = i + 2
            while j < input.count, input[j] >= 0x30, input[j] <= 0x3F { j += 1 }
            guard j < input.count else {
                if j - i <= Self.maxPending { pending = Array(input[i...]) }
                else { out.append(contentsOf: input[i...]) }
                break
            }
            if input[j] == Self.finalSGR, let params = rewriteSGR(input[(i + 2)..<j]) {
                out.append(Self.esc)
                out.append(Self.leftBracket)
                out.append(contentsOf: params)
                out.append(Self.finalSGR)
            } else {
                out.append(contentsOf: input[i...j])
            }
            i = j + 1
        }
        return out
    }

    /// Hand back whatever half-sequence is being held, because this adapter is about to stop being
    /// in the stream. The caller must feed it to the emulator.
    mutating func flushPending() -> [UInt8]? {
        guard !pending.isEmpty else { return nil }
        defer { pending = [] }
        return pending
    }

    // MARK: - SGR

    /// Returns the rewritten parameter bytes, or nil to leave the sequence exactly as it arrived.
    private mutating func rewriteSGR(_ params: ArraySlice<UInt8>) -> [UInt8]? {
        // Digits and semicolons only. A colon means the ITU subparameter form and a `?`/`<`/`=`/`>`
        // means this is not the SGR it looks like — either way, not a form modelled here.
        for b in params where !(b >= 0x30 && b <= 0x39) && b != Self.semicolon { return nil }

        var fields: [Int] = []
        var value = 0
        for b in params {
            if b == Self.semicolon {
                fields.append(value); value = 0
            } else {
                value = value * 10 + Int(b - 0x30)
                if value > 0xFFFF { return nil }                          // not a colour; hands off
            }
        }
        fields.append(value)   // also turns an empty `ESC[m` into its documented `0`

        var rewritten: [Int] = []
        rewritten.reserveCapacity(fields.count)
        var changed = false
        var k = 0
        while k < fields.count {
            let selector = fields[k]
            let isColour = selector == 38 || selector == 48
            if isColour, k + 4 < fields.count, fields[k + 1] == 2,
               fields[k + 2] < 256, fields[k + 3] < 256, fields[k + 4] < 256 {
                let (r, g, b) = (fields[k + 2], fields[k + 3], fields[k + 4])
                let (nr, ng, nb) = adapt(r: r, g: g, b: b, isForeground: selector == 38)
                if (nr, ng, nb) != (r, g, b) { changed = true }
                rewritten.append(contentsOf: [selector, 2, nr, ng, nb])
                k += 5
            } else if isColour, k + 2 < fields.count, fields[k + 1] == 5 {
                // Indexed — `TerminalPalette` already resolves this one for the appearance. Copied
                // as a unit so its argument can't be mistaken for a selector further along.
                rewritten.append(contentsOf: [selector, 5, fields[k + 2]])
                k += 3
            } else {
                rewritten.append(selector)
                k += 1
            }
        }
        guard changed else { return nil }

        var bytes: [UInt8] = []
        for (n, field) in rewritten.enumerated() {
            if n > 0 { bytes.append(Self.semicolon) }
            bytes.append(contentsOf: Array(String(field).utf8))
        }
        return bytes
    }

    // MARK: - Colour

    /// WCAG AA for body text. One number does both jobs: it decides which colours are in trouble
    /// and how far to move the ones that are.
    private static let minContrast = 4.5
    /// A fill dimmer than this is treated as a dark-theme block rather than a tint.
    private static let darkFillLuminance = 0.5

    private mutating func adapt(r: Int, g: Int, b: Int, isForeground: Bool) -> (Int, Int, Int) {
        let key = UInt32(r << 16 | g << 8 | b) | (isForeground ? 1 << 24 : 0)
        if let hit = memo[key] {
            return (Int(hit >> 16) & 0xFF, Int(hit >> 8) & 0xFF, Int(hit) & 0xFF)
        }
        let rgb = (Double(r) / 255, Double(g) / 255, Double(b) / 255)
        let adapted = isForeground ? Self.darkenForLight(rgb) : Self.lightenFill(rgb)
        let out = (Int((adapted.0 * 255).rounded()),
                   Int((adapted.1 * 255).rounded()),
                   Int((adapted.2 * 255).rounded()))
        memo[key] = UInt32(out.0 << 16 | out.1 << 8 | out.2)
        return out
    }

    /// Text. Inverting lightness alone is not enough: it rescues the pale greys a dark theme uses
    /// for body text, but a saturated mid-tone simply inverts to another mid-tone (#3FB950 becomes
    /// #4FBD5E — no better on white), so the result is walked darker until it measures up.
    ///
    /// Inverting *first* is what keeps the agent's own hierarchy: its brightest white lands at black
    /// and its dim grey at a dim dark grey, where darkening alone would flatten both onto the
    /// threshold and make every line the same weight.
    static func darkenForLight(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        if contrastOnWhite(rgb) >= minContrast { return rgb }             // already readable
        var (h, s, l) = toHSL(rgb)
        l = 1 - l
        var out = fromHSL(h, s, l)
        while contrastOnWhite(out) < minContrast && l > 0.02 {
            l -= 0.02
            out = fromHSL(h, s, l)
        }
        return out
    }

    /// A background fill. Dark blocks are inverted into tints — left dark they would swallow the
    /// text that has just been darkened onto them. Lightness inversion alone leaves a saturated
    /// fill (a pure blue sits at HSL lightness 0.5) exactly as dark as it started, so this one is
    /// walked in the other direction.
    static func lightenFill(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        if luminance(rgb) >= darkFillLuminance { return rgb }             // already a light tint
        var (h, s, l) = toHSL(rgb)
        l = 1 - l
        var out = fromHSL(h, s, l)
        while luminance(out) < darkFillLuminance && l < 0.98 {
            l += 0.02
            out = fromHSL(h, s, l)
        }
        return out
    }

    private static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    /// The light palette's background is pure white, so the usual `(L₁+0.05)/(L₂+0.05)` collapses.
    private static func contrastOnWhite(_ rgb: (Double, Double, Double)) -> Double {
        1.05 / (luminance(rgb) + 0.05)
    }

    static func toHSL(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let (r, g, b) = rgb
        let hi = max(r, g, b), lo = min(r, g, b)
        let l = (hi + lo) / 2
        guard hi > lo else { return (0, 0, l) }                           // grey: hue is meaningless
        let d = hi - lo
        let s = l > 0.5 ? d / (2 - hi - lo) : d / (hi + lo)
        var h: Double
        switch hi {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        return (h / 6, s, l)
    }

    static func fromHSL(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }
}
