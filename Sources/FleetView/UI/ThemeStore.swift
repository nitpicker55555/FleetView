import SwiftUI
import AppKit
import Observation

/// The seed colour the whole palette is generated from, and the colours it gives.
///
/// `Theme`'s roles read `colors` here, so a SwiftUI body that drew with any of them depends on it
/// through Observation and redraws when the seed changes. The colours are rebuilt as new `Color`s
/// on purpose: one long-lived dynamic `NSColor` that looked the seed up at draw time would paint the
/// new seed only wherever something else happened to redraw, because to SwiftUI it is the same
/// colour as before and nothing needs drawing again.
///
/// Kept in UserDefaults rather than state.json: it is a preference of this Mac's app, not part of
/// the board, and state.json's decode rules (see CLAUDE.md) are not worth risking for one value.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    static let defaultsKey = "themeSeed"
    /// Posted after the seed changes, for what draws outside SwiftUI — the file window's editor page.
    /// The web dashboard needs nothing: it sees `seed` change in `/state` and fetches `/theme.css`.
    static let didChange = Notification.Name("FleetViewThemeDidChange")

    private(set) var scheme: MaterialScheme
    /// One dynamic `Color` per `MaterialScheme.Role`, indexed by its raw value.
    private(set) var colors: [Color]

    var seed: UInt32 { scheme.seed }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(Self.parseHex)
        let scheme = MaterialScheme(seed: stored ?? MaterialScheme.defaultSeed)
        self.scheme = scheme
        colors = Self.colors(for: scheme)
    }

    /// `persist: false` is for `--snapshot`, which must not touch the app's preferences.
    func setSeed(_ rgb: UInt32, persist: Bool = true) {
        let rgb = rgb & 0xFF_FFFF
        guard rgb != scheme.seed else { return }
        scheme = MaterialScheme(seed: rgb)
        colors = Self.colors(for: scheme)
        if !persist {
        } else if rgb == MaterialScheme.defaultSeed {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.set(Self.hex(rgb), forKey: Self.defaultsKey)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static func colors(for scheme: MaterialScheme) -> [Color] {
        MaterialScheme.Role.allCases.map {
            Theme.dual(scheme.value($0, dark: true), scheme.value($0, dark: false))
        }
    }

    // MARK: Hex

    /// `#RRGGBB`, `RRGGBB` or `0xRRGGBB`.
    static func parseHex(_ s: String) -> UInt32? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("#") { t.removeFirst() } else if t.hasPrefix("0x") { t.removeFirst(2) }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return v
    }

    static func hex(_ v: UInt32) -> String { String(format: "#%06x", v & 0xFF_FFFF) }

    static func rgb(_ color: NSColor) -> UInt32? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        func ch(_ x: CGFloat) -> UInt32 { UInt32(max(0, min(255, (x * 255).rounded()))) }
        return ch(c.redComponent) << 16 | ch(c.greenComponent) << 8 | ch(c.blueComponent)
    }

    // MARK: Web dashboard

    /// The web dashboard's colour variables for this seed, laid over the page's own `:root` (dark)
    /// and `html.light` blocks — which keep #6750A4's values, so a page that never gets this still
    /// renders. Only the variables a seed moves are here; the white-on-dark washes and the error
    /// reds do not depend on it. The mapping mirrors the comments in WebDashboardPage's `:root`.
    func dashboardCSS() -> String { Self.dashboardCSS(scheme) }

    /// The same for any scheme — a web dashboard can take its own seed, on that device only
    /// (`/theme.css?seed=`), the way it can take its own light or dark.
    static func dashboardCSS(_ scheme: MaterialScheme) -> String {
        func block(_ dark: Bool) -> String {
            func v(_ r: MaterialScheme.Role) -> UInt32 { scheme.value(r, dark: dark) }
            func h(_ r: MaterialScheme.Role) -> String { hex(v(r)) }
            func a(_ r: MaterialScheme.Role, _ alpha: Double) -> String {
                let x = v(r)
                return "rgba(\(x >> 16 & 255),\(x >> 8 & 255),\(x & 255),\(alpha))"
            }
            var vars: [(String, String)] = [
                ("bg", h(.surface)), ("panel", h(.surfaceContainerLow)), ("card", h(.surfaceContainerHigh)),
                ("cardHover", h(.surfaceContainerHighest)), ("stroke", h(.outlineVariant)), ("text", h(.onSurface)),
                ("sub", h(.onSurfaceVariant)), ("accent", h(.primary)), ("green", h(.primary)),
                ("teal", h(.outline)), ("gray", h(.outline)), ("amber", h(.warn)), ("codex", h(.onSurface)),
                ("primaryContainer", h(.primaryContainer)), ("onPrimaryContainer", h(.onPrimaryContainer)),
                ("secondaryContainer", h(.secondaryContainer)), ("onSecondaryContainer", h(.onSecondaryContainer)),
                ("tertiary", h(.tertiary)), ("outline", h(.outline)), ("outlineVariant", h(.outlineVariant)),
                ("tertiaryContainer", h(.tertiaryContainer)), ("onTertiaryContainer", h(.onTertiaryContainer)),
                ("surfaceLowest", h(.surfaceContainerLowest)), ("surfaceHighest", h(.surfaceContainerHighest)),
                ("warnContainer", h(.warnContainer)), ("onWarnContainer", h(.onWarnContainer)),
                ("inverseSurface", h(.inverseSurface)), ("inverseOnSurface", h(.inverseOnSurface)),
                ("onAccent", h(.onPrimary)),
                ("runFresh", h(.runFresh)), ("onRunFresh", h(.onRunFresh)),
                ("runSettled", h(.runSettled)), ("onRunSettled", h(.onRunSettled)),
                ("quoteBg", h(.primaryContainer)), ("quoteFg", h(.onPrimaryContainer)),
                ("quoteEdge", a(.onPrimaryContainer, dark ? 0.08 : 0.12)),
                ("markBg", h(.surfaceContainerHigh)), ("markTint", h(.tertiary)),
                ("quoteBgSoft", a(.primaryContainer, dark ? 0.88 : 0.9)),
                ("codeBg", h(dark ? .surfaceContainerLowest : .surfaceContainer)),
                ("headerBg", a(.surface, 0.94)),
                ("accentSoft", a(.primary, dark ? 0.14 : 0.10)), ("accentFaint", a(.primary, dark ? 0.06 : 0.045)),
                ("accentEdge", a(.primary, dark ? 0.30 : 0.32)), ("accentEdgeOn", a(.primary, 0.55)),
                ("amberSoft", a(.warn, dark ? 0.12 : 0.10)), ("amberEdge", a(.warn, 0.38)),
                ("greenSoft", a(.primary, dark ? 0.14 : 0.10)), ("greenEdge", a(.primary, dark ? 0.30 : 0.32)),
                ("greenFg", h(.onPrimaryContainer)),
                ("quoteCodeFg", h(.onPrimaryContainer)), ("quoteLink", h(.primary)),
                ("quoteEdgeSoft", a(.onPrimaryContainer, 0.28)),
            ]
            if !dark {
                // Dark mode's washes are white at an alpha; light mode's are tinted by the scheme.
                vars += [("codeInline", a(.onSurface, 0.07)), ("skel1", a(.onSurface, 0.05)),
                         ("skel2", a(.onSurface, 0.11)), ("skelU1", a(.onPrimaryContainer, 0.10)),
                         ("skelU2", a(.onPrimaryContainer, 0.20)), ("quoteCode", a(.onPrimaryContainer, 0.10))]
            }
            return vars.map { "--\($0.0):\($0.1)" }.joined(separator: ";")
        }
        return ":root{\(block(true))}\nhtml.light{\(block(false))}"
    }

    /// What the web's colour sheet draws for a seed, as the Mac's dialog does: the primary over the
    /// secondary and tertiary containers, in each appearance.
    static func swatch(_ seed: UInt32) -> [String: Any] {
        let s = MaterialScheme(seed: seed)
        func three(_ dark: Bool) -> [String] {
            [.primary, .secondaryContainer, .tertiaryContainer].map { hex(s.value($0, dark: dark)) }
        }
        return ["seed": hex(seed), "dark": three(true), "light": three(false)]
    }
}
