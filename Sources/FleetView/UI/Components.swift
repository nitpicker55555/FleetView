import SwiftUI

/// Inline-editable text. Double-click to edit, or drive `editing` externally (e.g. from a
/// menu / pencil button). Commits on Return, cancels on Esc.
struct EditableText: View {
    let text: String
    var font: Font = .system(size: 14, weight: .semibold)
    var color: Color = Theme.text
    var placeholder: String = "name"
    let onCommit: (String) -> Void
    @Binding var editing: Bool

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundColor(color)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
            } else {
                Text(text)
                    .font(font)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { editing = true }
            }
        }
        .onChange(of: editing) { _, isEditing in
            if isEditing {
                draft = text
                DispatchQueue.main.async { focused = true }
            }
        }
    }

    private func commit() {
        editing = false
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { onCommit(t) }
    }
}
