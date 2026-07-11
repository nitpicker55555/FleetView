import SwiftUI

/// Small dialog to name a new terminal (before it opens) or rename an existing one.
struct NameSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let request: AppState.NameSheetRequest

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)

            TextField("terminal name", text: $name)
                .textFieldStyle(.plain).font(.system(size: 14))
                .padding(9)
                .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
                .foregroundColor(Theme.text)
                .focused($focused)
                .onSubmit(confirm)

            HStack {
                Spacer()
                Button("Cancel") { state.nameSheet = nil; dismiss() }
                Button(request.confirmLabel, action: confirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(Theme.bg)
        .onAppear {
            name = request.initialName
            DispatchQueue.main.async { focused = true }
        }
    }

    private func confirm() {
        state.confirmName(name)
        dismiss()
    }
}
