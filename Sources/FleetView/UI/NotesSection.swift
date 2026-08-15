import SwiftUI
import AppKit

/// The sidebar's collapsible "NOTES" section: quick free-form text items.
/// Single-click a note to copy it, double-click to edit (also via right-click).
struct NotesSection: View {
    @EnvironmentObject var state: AppState
    /// When the Tasks section is collapsed, let the notes list grow to fill the sidebar.
    var fill: Bool = false

    @State private var newNote = ""
    @State private var filter = ""
    @FocusState private var addFocused: Bool
    @FocusState private var filterFocused: Bool

    private var query: String { filter.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Notes matching the filter (case-insensitive substring).
    private var shown: [Note] {
        query.isEmpty ? state.notes : state.notes.filter { $0.text.lowercased().contains(query) }
    }

    /// Other machines' notes, filtered by the same box. The peer's name is searchable too, so
    /// "reginabai" narrows the list to one machine without a separate control for it.
    private var shownPeer: [MirroredNote] {
        query.isEmpty ? state.peerNotes
                      : state.peerNotes.filter {
                            $0.text.lowercased().contains(query) || $0.from.lowercased().contains(query)
                        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !state.notesCollapsed {
                if state.notes.isEmpty && state.peerNotes.isEmpty {
                    Text("Click to copy · double-click to edit")
                        .font(.system(size: 11)).foregroundColor(Theme.subtext.opacity(0.5))
                        .padding(.horizontal, 16).padding(.vertical, 6)
                } else {
                    // Counted across both lists: the row earns its place once the list is long,
                    // and a list is long whether the length came from here or from a peer.
                    if state.notes.count + state.peerNotes.count > 5 { filterField }
                    if shown.isEmpty && shownPeer.isEmpty {
                        Text("No note matches “\(filter)”")
                            .font(.system(size: 11)).foregroundColor(Theme.subtext.opacity(0.6))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                    } else {
                        ScrollView {
                            VStack(spacing: 3) {
                                ForEach(shown) { NoteRow(note: $0) }
                                // Mirrored rows come after the local ones and carry their origin,
                                // so the list never leaves you guessing whose note you are about
                                // to edit — every one of these writes to another machine.
                                ForEach(shownPeer) { PeerNoteRow(note: $0) }
                            }
                            .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
                        }
                        .frame(maxHeight: fill ? .infinity : 240)
                    }
                }
                addField
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10))
                .foregroundColor(Theme.subtext.opacity(0.8))
            TextField("Filter notes", text: $filter)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(Theme.text)
                .focused($filterFocused)
                .onExitCommand { filter = "" }
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        .foregroundColor(Theme.subtext.opacity(0.7))
                }
                .buttonStyle(.plain).help("Clear filter")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Theme.card.opacity(filterFocused ? 0.95 : 0.45))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(filterFocused ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1))
        .padding(.horizontal, 12).padding(.bottom, 5)
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
                if state.peerNotesLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.45)
                } else if !state.peerNotes.isEmpty {
                    // Kept apart from the local count rather than summed: these live on other
                    // machines and can vanish when a laptop closes, and a single total would make
                    // that look like your own notes disappearing.
                    Text("+\(state.peerNotes.count)")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent)
                        .help("\(state.peerNotes.count) notes mirrored from other FleetViews")
                }
                Text(filter.isEmpty ? "\(state.notes.count)" : "\(shown.count)/\(state.notes.count)")
                    .font(.system(size: 11)).foregroundColor(Theme.subtext.opacity(0.7))
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

/// A note living on another FleetView, shown here with where it came from.
///
/// Editing and deleting reach across the network to that machine, so the origin tag is not
/// decoration: it is the only thing distinguishing a row that changes a file on this Mac from one
/// that changes somebody else's. The write goes out and the list is re-read — what you end up
/// looking at is what that machine actually holds, not what this one hoped it would.
struct PeerNoteRow: View {
    @EnvironmentObject var state: AppState
    let note: MirroredNote

    @State private var editing = false
    @State private var draft = ""
    @State private var copied = false
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        if editing { editor } else { row }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.text.isEmpty ? "empty note" : note.text)
                .font(.system(size: 12.5))
                .foregroundColor(note.text.isEmpty ? Theme.subtext.opacity(0.5) : Theme.text)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Image(systemName: "network").font(.system(size: 8))
                Text("from \(note.from)").font(.system(size: 9.5, weight: .medium))
            }
            .foregroundColor(Theme.accent.opacity(0.85))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hover ? Theme.cardHover : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .topTrailing) { if copied { copiedChip } }
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(Theme.accent.opacity(0.22), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { beginEdit() }
        .onTapGesture { copy() }
        .contextMenu {
            Button("Copy") { copy() }
            Button("Edit on \(note.from)") { beginEdit() }
            Divider()
            Button("Delete on \(note.from)", role: .destructive) { state.removePeerNote(note) }
        }
        .help("From \(note.from) · click to copy · double-click to edit it there")
    }

    private var copiedChip: some View {
        Text("Copied").font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Theme.green).clipShape(Capsule())
            .padding(6)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private var editor: some View {
        HStack(spacing: 7) {
            TextField("note on \(note.from)", text: $draft)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundColor(Theme.text)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { editing = false }
            Button(action: commit) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.green)
            }.buttonStyle(.plain).help("Save on \(note.from)")
            Button { editing = false } label: {
                Image(systemName: "xmark").font(.system(size: 12)).foregroundColor(Theme.subtext)
            }.buttonStyle(.plain).help("Cancel")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.accent.opacity(0.55), lineWidth: 1))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
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
        state.updatePeerNote(note, text: draft)
    }
}

/// A single note row. Single-click copies it, double-click edits it (also via right-click).
struct NoteRow: View {
    @EnvironmentObject var state: AppState
    let note: Note

    @State private var editing = false
    @State private var draft = ""
    @State private var copied = false
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        if editing { editor } else { row }
    }

    // MARK: - Display

    private var row: some View {
        Text(note.text.isEmpty ? "empty note" : note.text)
            .font(.system(size: 12.5))
            .foregroundColor(note.text.isEmpty ? Theme.subtext.opacity(0.5) : Theme.text)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hover ? Theme.cardHover : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .trailing) { if copied { copiedChip } }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(count: 2) { beginEdit() }   // double-click → edit
            .onTapGesture { copy() }                  // single-click → copy
            .contextMenu {
                Button("Copy") { copy() }
                Button("Edit") { beginEdit() }
                Divider()
                Button("Delete", role: .destructive) { withAnimation { state.removeNote(note.id) } }
            }
            .help("Click to copy · double-click to edit")
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

    // MARK: - Actions

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
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
