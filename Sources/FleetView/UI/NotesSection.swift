import SwiftUI
import AppKit

/// The sidebar's collapsible "笔记" section: quick free-form text items.
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

    /// Whose notes this list is showing. Selecting a peer turns the whole sidebar to that machine,
    /// so the list follows: mixing your own notes in would leave you reading a list that is half
    /// this Mac and half another one, with no way to tell at a glance which half you were acting on.
    private var viewingPeer: Peer? { state.peerSelected }

    /// Local notes — none of them while a peer is being viewed.
    private var shown: [Note] {
        guard viewingPeer == nil else { return [] }
        return query.isEmpty ? state.notes : state.notes.filter { $0.text.lowercased().contains(query) }
    }

    /// The selected peer's notes — and nothing at all when no peer is selected.
    ///
    /// Finding a machine on the network is not a request to read its notes. Merging them in on
    /// discovery quietly grew this list by other people's items, and the count going up was the
    /// only warning. They appear when you go and look at that machine, which is when you asked.
    private var shownPeer: [MirroredNote] {
        guard let p = viewingPeer else { return [] }
        let pool = state.peerNotes.filter { $0.peerURL == p.url }
        return query.isEmpty ? pool : pool.filter { $0.text.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !state.notesCollapsed {
                if shown.isEmpty && shownPeer.isEmpty && query.isEmpty {
                    Text(viewingPeer == nil ? L(.notesHint)
                                            : L(.notesPeerEmpty(viewingPeer!.label)))
                        .font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                } else {
                    // Counted across whatever is in view: the row earns its place once the list is
                    // long, and a list is long whether the length came from here or from a peer.
                    if state.notes.count + state.peerNotes.count > 5 { filterField }
                    if shown.isEmpty && shownPeer.isEmpty {
                        Text(L(.notesNoMatch(filter)))
                            .font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                    } else {
                        ScrollView {
                            VStack(spacing: 2) {
                                // Rows handed `state` to act on, not observing it, and compared
                                // before they are redrawn: observing, all of them were redrawn on
                                // every write to it anywhere (see TaskRow).
                                ForEach(shown) { NoteRow(state: state, note: $0).equatable() }
                                // Mirrored rows come after the local ones and carry their origin,
                                // so the list never leaves you guessing whose note you are about
                                // to edit — every one of these writes to another machine.
                                ForEach(shownPeer) { PeerNoteRow(state: state, note: $0).equatable() }
                            }
                            .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 4)
                        }
                        .frame(maxHeight: fill ? .infinity : 240)
                    }
                }
                addField
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13))
                .foregroundColor(Theme.onSurfaceVariant)
            TextField(L(.notesFilter), text: $filter)
                .textFieldStyle(.plain).font(.fvBodySmall).foregroundColor(Theme.onSurface)
                .focused($filterFocused)
                .onExitCommand { filter = "" }
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                        .foregroundColor(Theme.onSurfaceVariant)
                }
                .buttonStyle(.plain).help(L(.clear))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.controlHeight)
        .background(Theme.surfaceContainerHigh)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(filterFocused ? Theme.primary : Color.clear, lineWidth: 1))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private var header: some View {
        SidebarSectionHeader(title: L(.notesTitle),
                             count: viewingPeer == nil ? state.notes.count : shownPeer.count,
                             collapsed: state.notesCollapsed) {
            withAnimation(.easeOut(duration: 0.18)) { state.notesCollapsed.toggle() }
            state.save()
        } accessory: {
            if let p = viewingPeer {
                // Named in the header, not only on the rows: this list is somebody else's while
                // a peer is selected, and every edit made in it lands on their machine.
                Text(L(.notesFrom(p.label)))
                    .font(.fvLabelSmall).foregroundColor(Theme.primary)
                    .lineLimit(1)
                if state.peerNotesLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.45)
                }
            }
        }
    }

    private var addField: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.primary)
            TextField(viewingPeer == nil ? L(.notesAdd) : L(.notesAddOn(viewingPeer!.label)),
                      text: $newNote)
                .textFieldStyle(.plain).font(.fvBodySmall).foregroundColor(Theme.onSurface)
                .focused($addFocused)
                .onSubmit(add)
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.controlHeight)
        .background(addFocused ? Theme.surfaceContainerHigh : Color.clear)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(addFocused ? Theme.primary : Color.clear, lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 8)
    }

    /// Adds where the list is pointing. While a peer is selected the whole section is that
    /// machine's, so a note typed here belongs there — writing it locally would put it somewhere
    /// the list is not even showing.
    private func add() {
        let text = newNote
        newNote = ""
        if let p = viewingPeer { state.addPeerNote(to: p, text: text) } else { state.addNote(text) }
    }
}

/// A note living on another FleetView, shown here with where it came from.
///
/// Editing and deleting reach across the network to that machine, so the origin tag is not
/// decoration: it is the only thing distinguishing a row that changes a file on this Mac from one
/// that changes somebody else's. The write goes out and the list is re-read — what you end up
/// looking at is what that machine actually holds, not what this one hoped it would.
struct PeerNoteRow: View, Equatable {
    let state: AppState
    let note: MirroredNote

    nonisolated static func == (a: PeerNoteRow, b: PeerNoteRow) -> Bool { a.note == b.note }

    @State private var editing = false
    @State private var draft = ""
    @State private var copied = false
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        if editing { editor } else { row }
    }

    /// No per-row origin tag: the whole section belongs to one machine while a peer is selected and
    /// the header says which, so repeating it on every row was the same sentence N times.
    private var row: some View {
        Text(note.text.isEmpty ? L(.notesEmpty) : note.text)
            .font(.fvMonoBody)
            .foregroundColor(note.text.isEmpty ? Theme.onSurfaceVariant : Theme.onSurface)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 7)
        .background(hover ? Theme.surfaceContainerHigh : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(alignment: .topTrailing) { if copied { copiedChip } }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { beginEdit() }
        .onTapGesture { copy() }
        .contextMenu {
            Button(L(.copy)) { copy() }
            Button(L(.notesEditOn(note.from))) { beginEdit() }
            Divider()
            Button(L(.notesDeleteOn(note.from)), role: .destructive) { state.removePeerNote(note) }
        }
        .help(L(.notesPeerHelp(note.from)))
    }

    private var copiedChip: some View {
        Text(L(.copied)).font(.fvLabelSmall).foregroundColor(Theme.onPrimary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Theme.primary).clipShape(Capsule())
            .padding(6)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private var editor: some View {
        HStack(spacing: 7) {
            TextField(L(.notesPeerField(note.from)), text: $draft)
                .textFieldStyle(.plain).font(.fvMonoBody).foregroundColor(Theme.onSurface)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { editing = false }
            Button(action: commit) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.green)
            }.buttonStyle(.plain).help(L(.notesSaveOn(note.from)))
            Button { editing = false } label: {
                Image(systemName: "xmark").font(.system(size: 12)).foregroundColor(Theme.subtext)
            }.buttonStyle(.plain).help(L(.cancel))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.surfaceContainerHigh).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.primary, lineWidth: 1))
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
struct NoteRow: View, Equatable {
    let state: AppState
    let note: Note

    nonisolated static func == (a: NoteRow, b: NoteRow) -> Bool { a.note == b.note }

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
        Text(note.text.isEmpty ? L(.notesEmpty) : note.text)
            .font(.fvMonoBody)
            .foregroundColor(note.text.isEmpty ? Theme.onSurfaceVariant : Theme.onSurface)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(hover ? Theme.surfaceContainerHigh : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(alignment: .trailing) { if copied { copiedChip } }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(count: 2) { beginEdit() }   // double-click → edit
            .onTapGesture { copy() }                  // single-click → copy
            .contextMenu {
                Button(L(.copy)) { copy() }
                Button(L(.edit)) { beginEdit() }
                Divider()
                Button(L(.delete), role: .destructive) { withAnimation { state.removeNote(note.id) } }
            }
            .help(L(.notesHint))
    }

    private var copiedChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
            Text(L(.copied))
        }
        .font(.fvLabelSmall).foregroundColor(Theme.onPrimary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.primary).clipShape(Capsule())
        .padding(.trailing, 6)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    // MARK: - Editor

    private var editor: some View {
        HStack(spacing: 7) {
            TextField(L(.notesField), text: $draft)
                .textFieldStyle(.plain).font(.fvMonoBody).foregroundColor(Theme.onSurface)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
            Button(action: commit) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.green)
            }.buttonStyle(.plain).help(L(.save))
            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 12)).foregroundColor(Theme.subtext)
            }.buttonStyle(.plain).help(L(.cancel))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.surfaceContainerHigh).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.primary, lineWidth: 1))
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
