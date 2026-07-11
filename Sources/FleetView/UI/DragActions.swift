import SwiftUI
import UniformTypeIdentifiers

/// Floating dock of drop zones shown while a terminal card is being dragged. Drop the card on a
/// zone to run that action on it. (Requirement: menu actions via drag-and-drop.)
struct ActionDock: View {
    @EnvironmentObject var state: AppState
    let terminalId: UUID

    private var terminal: TerminalSession? { state.terminals.first { $0.id == terminalId } }

    var body: some View {
        let inCluster = terminal?.clusterId != nil
        let done = terminal?.subtaskDone ?? false

        HStack(spacing: 10) {
            zone(done ? "Not Done" : "Done", done ? "circle" : "checkmark.circle.fill", Theme.green) {
                state.toggleSubtaskDone(terminalId)
            }
            zone("Duplicate", "plus.square.on.square", Theme.accent) {
                state.duplicateTerminal(terminalId)
            }
            zone("Rename", "pencil", Color(red: 0.62, green: 0.64, blue: 0.72)) {
                state.requestRename(terminalId)
            }
            if inCluster {
                zone("Leave Cluster", "arrow.up.forward.square", Color(red: 0.98, green: 0.72, blue: 0.32)) {
                    state.removeFromCluster(terminalId)
                }
            }
            zone("Remove", "trash", Color(red: 0.90, green: 0.42, blue: 0.45)) {
                state.removeTerminal(terminalId)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .padding(.bottom, 26)
    }

    private func zone(_ title: String, _ icon: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        ActionDropZone(title: title, icon: icon, tint: tint) {
            action()
            state.endDrag()
        }
    }
}

struct ActionDropZone: View {
    let title: String
    let icon: String
    let tint: Color
    let onPerform: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18)).foregroundColor(targeted ? .white : tint)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(targeted ? .white : Theme.subtext)
        }
        .frame(width: 96, height: 66)
        .background(targeted ? tint : tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(targeted ? 0.9 : 0.35), lineWidth: 1))
        .scaleEffect(targeted ? 1.07 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: targeted)
        .onDrop(of: [.text], isTargeted: $targeted) { _ in
            onPerform()
            return true
        }
    }
}
