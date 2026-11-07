import SwiftUI
import AppKit

/// FleetView → 配色…: the seed colour the whole palette is generated from.
///
/// Five swatches — the website's seed picker's five, so the two can be compared — and a sixth that
/// opens the system colour panel for any seed at all. The board stays at full strength behind this
/// dialog (see `DashboardView.dashboardReceded`): what a seed looks like is the board, not a sample.
struct ThemeDialog: View {
    @EnvironmentObject var state: AppState
    @State private var panel = SeedColorPanel()

    var body: some View {
        let store = ThemeStore.shared
        let seed = store.seed
        let isPreset = MaterialScheme.presets.contains { $0.seed == seed }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "paintpalette").font(.system(size: 16)).foregroundColor(Theme.primary)
                Text(L(.themeTitle)).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                Spacer()
                Text(ThemeStore.hex(seed).uppercased()).font(.fvMono).foregroundColor(Theme.onSurfaceVariant)
                    .textSelection(.enabled)
            }
            .padding(.bottom, 12)
            Text(L(.themeBody)).font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                ForEach(MaterialScheme.presets, id: \.seed) { p in
                    option(L(.themeSeedName(p.name)), selected: seed == p.seed) {
                        SeedSwatch(scheme: SeedSwatch.scheme(p.seed))
                    } action: {
                        panel.close()
                        store.setSeed(p.seed)
                    }
                }
                option(L(.themeCustom), selected: !isPreset) {
                    if isPreset {
                        // Every hue at once: "any colour", before one has been picked.
                        Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                      center: .center))
                            .overlay(Image(systemName: "eyedropper").font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white).shadow(radius: 1))
                    } else {
                        SeedSwatch(scheme: store.scheme)
                    }
                } action: {
                    panel.open(seed: seed)
                }
            }
            .padding(.top, 20)
            HStack(spacing: 8) {
                if seed != MaterialScheme.defaultSeed {
                    Button {
                        panel.close()
                        store.setSeed(MaterialScheme.defaultSeed)
                    } label: {
                        Text(L(.themeReset)).font(.fvLabel).foregroundColor(Theme.primary)
                            .padding(.horizontal, 12).frame(height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { state.dialog = nil } label: {
                    Text(L(.themeDone)).font(.fvLabel).foregroundColor(Theme.onPrimary)
                        .padding(.horizontal, 20).frame(height: 40)
                        .background(Theme.primary).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .padding(24)
        .frame(width: 420)
        .onDisappear { panel.close() }
    }

    private func option<Swatch: View>(_ name: String, selected: Bool, @ViewBuilder swatch: () -> Swatch,
                                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                swatch()
                    .frame(width: 40, height: 40)
                    .padding(4)
                    .overlay(Circle().strokeBorder(selected ? Theme.onSurface : .clear, lineWidth: 2))
                Text(name).font(.fvLabelSmall)
                    .foregroundColor(selected ? Theme.onSurface : Theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(width: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
    }
}

/// A seed drawn the way Android's colour picker draws one: the primary on top, the secondary and
/// tertiary containers below — the three things a seed actually changes, rather than the seed
/// itself, which no role uses as is.
private struct SeedSwatch: View {
    let scheme: MaterialScheme
    @Environment(\.colorScheme) private var colorScheme

    private static var cache: [UInt32: MaterialScheme] = [:]
    static func scheme(_ seed: UInt32) -> MaterialScheme {
        if let s = cache[seed] { return s }
        let s = MaterialScheme(seed: seed)
        cache[seed] = s
        return s
    }

    var body: some View {
        let dark = colorScheme == .dark
        func c(_ r: MaterialScheme.Role) -> Color {
            let v = scheme.value(r, dark: dark)
            return Color(.sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255,
                         blue: Double(v & 255) / 255)
        }
        return GeometryReader { g in
            let h = g.size.height / 2
            ZStack(alignment: .top) {
                c(.primary)
                HStack(spacing: 0) {
                    c(.secondaryContainer)
                    c(.tertiaryContainer)
                }
                .frame(height: h)
                .offset(y: h)
            }
        }
        .clipShape(Circle())
    }
}

/// The system colour panel, driving the seed while it is open.
///
/// The panel reports every step of a drag; each seed redraws the whole app, so the steps are
/// coalesced to one every 50 ms rather than queued.
final class SeedColorPanel: NSObject {
    private var latest: UInt32?
    private var scheduled = false
    /// Whether the shared panel is ours right now; it has no getter for its target to ask.
    private var owning = false

    func open(seed: UInt32) {
        let p = NSColorPanel.shared
        p.showsAlpha = false
        p.setTarget(self)
        p.setAction(#selector(changed(_:)))
        owning = true
        p.color = NSColor(srgbRed: Double(seed >> 16 & 255) / 255, green: Double(seed >> 8 & 255) / 255,
                          blue: Double(seed & 255) / 255, alpha: 1)
        p.orderFront(nil)
    }

    func close() {
        guard owning else { return }
        owning = false
        let p = NSColorPanel.shared
        p.setTarget(nil)
        p.setAction(nil)
        p.orderOut(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        guard owning, let rgb = ThemeStore.rgb(sender.color) else { return }
        latest = rgb
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            if let v = self.latest { ThemeStore.shared.setSeed(v) }
        }
    }
}
