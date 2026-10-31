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
        HStack(spacing: 6) {
            ForEach(zones) { zone in
                ActionZoneView(zone: zone, done: done, hovered: state.hoveredZone == zone)
            }
        }
        .padding(8)
        .background(Theme.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.dialog))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .padding(.bottom, 24)
    }
}

struct ActionZoneView: View {
    let zone: AppState.DragZone
    let done: Bool
    let hovered: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 18))
            Text(title).font(.fvLabelSmall)
        }
        .foregroundColor(fg)
        .frame(width: 84, height: 64)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ZoneFrameKey.self, value: [zone: geo.frame(in: .named("fleet"))])
            }
        )
    }

    private var destructive: Bool { zone == .remove }
    private var fg: Color {
        if hovered { return destructive ? Theme.onErrorContainer : Theme.onSecondaryContainer }
        return destructive ? Theme.error : Theme.onSurfaceVariant
    }
    private var bg: Color {
        guard hovered else { return .clear }
        return destructive ? Theme.errorContainer : Theme.secondaryContainer
    }

    private var title: String {
        switch zone {
        case .done:         return done ? L(.dockUnmark) : L(.dockMark)
        case .duplicate:    return L(.dockDuplicate)
        case .rename:       return L(.dockRename)
        case .tree:         return L(.dockTree)
        case .share:        return L(.dockShare)
        case .leaveCluster: return L(.dockLeaveCluster)
        case .remove:       return L(.dockRemove)
        }
    }

    private var icon: String {
        switch zone {
        case .done:         return done ? "bookmark.slash" : "bookmark"
        case .duplicate:    return "plus.square.on.square"
        case .rename:       return "pencil"
        case .tree:         return "arrow.triangle.branch"
        case .share:        return "square.and.arrow.up"
        case .leaveCluster: return "rectangle.portrait.and.arrow.right"
        case .remove:       return "trash"
        }
    }
}

/// What releasing here will do, next to the cursor, as an inverse-surface label (Material's
/// tooltip/snackbar surface, so it never reads as one more card).
///
/// `hint` names what releasing HERE will do; the ring around the target says *where*. Nil when the
/// cursor is over nothing that would act, so the label never promises an outcome.
///
/// `note` is for a drop that does more than rearrange the board. Moving a card to another project
/// also moves a file on disk and restarts an agent, and neither of those is undone by dragging the
/// card back — so it is said before the mouse comes up, not discovered afterwards.
struct DragHintLabel: View {
    let hint: String
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hint).font(.fvLabel).lineLimit(1)
            if let note {
                Text(note).font(.fvLabelSmall).opacity(0.8).lineLimit(1)
            }
        }
        .foregroundColor(Theme.inverseOnSurface)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.inverseSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}
