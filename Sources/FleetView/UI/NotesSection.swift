import SwiftUI
import AppKit

/// The sidebar's collapsible "NOTES" section: quick free-form text items.
/// Swipe a note LEFT to copy it, RIGHT to edit it (also via double-click / right-click).
struct NotesSection: View {
    @EnvironmentObject var state: AppState
    /// When the Tasks section is collapsed, let the notes list grow to fill the sidebar.
    var fill: Bool = false

    @State private var newNote = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !state.notesCollapsed {
                if state.notes.isEmpty {
                    Text("Swipe left to copy · right to edit")
                        .font(.system(size: 11)).foregroundColor(Theme.subtext.opacity(0.5))
                        .padding(.horizontal, 16).padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(state.notes) { NoteRow(note: $0) }
                        }
                        .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
                    }
                    .frame(maxHeight: fill ? .infinity : 240)
                }
                addField
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { state.notesCollapsed.toggle() }
            state.save()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(Theme.subtext)
                    .rotationEffect(.degrees(state.notesCollapsed ? 0 : 90))
                Text("NOTES").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.subtext)
                Spacer()
                Text("\(state.notes.count)").font(.system(size: 11)).foregroundColor(Theme.subtext.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var addField: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus.circle.fill").font(.system(size: 12))
                .foregroundColor(Theme.accent.opacity(0.85))
            TextField("Add a note…", text: $newNote)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundColor(Theme.text)
                .focused($addFocused)
                .onSubmit(add)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.card.opacity(addFocused ? 0.95 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(addFocused ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 3).padding(.bottom, 10)
    }

    private func add() {
        state.addNote(newNote)
        newNote = ""
    }
}

/// A single note row. Drag horizontally to reveal an action: left ⇒ copy, right ⇒ edit.
struct NoteRow: View {
    @EnvironmentObject var state: AppState
    let note: Note

    @State private var offset: CGFloat = 0
    @State private var editing = false
    @State private var draft = ""
    @State private var copied = false
    @State private var hover = false
    @FocusState private var focused: Bool

    private let threshold: CGFloat = 48    // pull past this to trigger the action
    private let maxPull: CGFloat = 76      // clamp so the row never slides off

    var body: some View {
        if editing { editor } else { row }
    }

    // MARK: - Display (swipeable)

    private var row: some View {
        ZStack {
            backdrops
            content
        }
    }

    private var backdrops: some View {
        HStack(spacing: 0) {
            swipeLabel(icon: "pencil", text: "Edit", tint: Theme.accent, engaged: offset >= threshold)
                .opacity(revealOpacity(offset))
            Spacer(minLength: 0)
            swipeLabel(icon: "doc.on.doc", text: "Copy", tint: Theme.green, engaged: offset <= -threshold)
                .opacity(revealOpacity(-offset))
        }
        .padding(.horizontal, 14)
    }

    private var content: some View {
        Text(note.text.isEmpty ? "empty note" : note.text)
            .font(.system(size: 12.5))
            .foregroundColor(note.text.isEmpty ? Theme.subtext.opacity(0.5) : Theme.text)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hover ? Theme.cardHover : Theme.card)   // opaque: hides the backdrops until swiped
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .trailing) { if copied { copiedChip } }
            .offset(x: offset)
            .onHover { hover = $0 }
            .gesture(swipe)
            .onTapGesture(count: 2) { beginEdit() }
            .contextMenu {
                Button("Edit") { beginEdit() }
                Button("Copy") { copy() }
                Divider()
                Button("Delete", role: .destructive) { withAnimation { state.removeNote(note.id) } }
            }
            .help(note.text)
    }

    private var copiedChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
            Text("Copied")
        }
        .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.green).clipShape(Capsule())
        .padding(.trailing, 6)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private func swipeLabel(icon: String, text: String, tint: Color, engaged: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(engaged ? .white : tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(engaged ? tint : tint.opacity(0.16), in: Capsule())
        .scaleEffect(engaged ? 1.06 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: engaged)
    }

    private func revealOpacity(_ v: CGFloat) -> Double { Double(max(0, min(1, v / threshold))) }

    // MARK: - Editor

    private var editor: some View {
        HStack(spacing: 7) {
            TextField("note", text: $draft)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundColor(Theme.text)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
            Button(action: commit) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.green)
            }.buttonStyle(.plain).help("Save")
            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 12)).foregroundColor(Theme.subtext)
            }.buttonStyle(.plain).help("Cancel")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.accent.opacity(0.55), lineWidth: 1))
        .onChange(of: focused) { _, f in if !f && editing { commit() } }   // commit on click-away
    }

    // MARK: - Gesture + actions

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }   // horizontal only
                offset = max(-maxPull, min(maxPull, v.translation.width))
            }
            .onEnded { v in
                let w = v.translation.width
                if w <= -threshold { copy() }
                else if w >= threshold { snapBack(); beginEdit(); return }
                snapBack()
            }
    }

    private func snapBack() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { offset = 0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        snapBack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }

    private func beginEdit() {
        draft = note.text
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        editing = false
        state.updateNote(note.id, text: draft)
    }

    private func cancel() {
        editing = false
        draft = note.text
    }
}
