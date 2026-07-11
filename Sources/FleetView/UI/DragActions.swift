import SwiftUI

/// Zones report their frames (in the "fleet" coordinate space) up to the dashboard, which hit-tests
/// the drag point against them — deterministic, no reliance on system drop delivery.
struct ZoneFrameKey: PreferenceKey {
    static var defaultValue: [AppState.DragZone: CGRect] = [:]
    static func reduce(value: inout [AppState.DragZone: CGRect], nextValue: () -> [AppState.DragZone: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Floating dock of action zones shown while a terminal card is being dragged.
struct ActionDock: View {
    @EnvironmentObject var state: AppState
    let terminalId: UUID

    private var zones: [AppState.DragZone] { state.availableZones(for: terminalId) }
    private var done: Bool { state.terminals.first { $0.id == terminalId }?.subtaskDone ?? false }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(zones) { zone in
                ActionZoneView(zone: zone, done: done, hovered: state.hoveredZone == zone)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .padding(.bottom, 26)
    }
}

struct ActionZoneView: View {
    let zone: AppState.DragZone
    let done: Bool
    let hovered: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18)).foregroundColor(hovered ? .white : tint)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(hovered ? .white : Theme.subtext)
        }
        .frame(width: 96, height: 66)
        .background(hovered ? tint : tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(hovered ? 0.9 : 0.35), lineWidth: 1))
        .scaleEffect(hovered ? 1.08 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: hovered)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ZoneFrameKey.self, value: [zone: geo.frame(in: .named("fleet"))])
            }
        )
    }

    private var title: String {
        switch zone {
        case .done:         return done ? "Not Done" : "Done"
        case .duplicate:    return "Duplicate"
        case .rename:       return "Rename"
        case .leaveCluster: return "Leave Cluster"
        case .remove:       return "Remove"
        }
    }

    private var icon: String {
        switch zone {
        case .done:         return done ? "circle" : "checkmark.circle.fill"
        case .duplicate:    return "plus.square.on.square"
        case .rename:       return "pencil"
        case .leaveCluster: return "arrow.up.forward.square"
        case .remove:       return "trash"
        }
    }

    private var tint: Color {
        switch zone {
        case .done:         return Theme.green
        case .duplicate:    return Theme.accent
        case .rename:       return Color(red: 0.62, green: 0.64, blue: 0.72)
        case .leaveCluster: return Color(red: 0.98, green: 0.72, blue: 0.32)
        case .remove:       return Color(red: 0.90, green: 0.42, blue: 0.45)
        }
    }
}

/// The chip that follows the cursor while dragging (so the real card never moves).
struct DragPreviewChip: View {
    let name: String
    let status: TermStatus

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(status: status)
            Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.card).clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.accent.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}
