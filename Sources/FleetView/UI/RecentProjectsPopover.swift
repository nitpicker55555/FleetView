import SwiftUI

/// What the toolbar's folder button opens: every project the board has had, most recently used
/// first (`AppState.recentProjectRows`), with how many removed cards each still holds.
///
/// The board only shows what is open, and a project closed to keep it tidy used to be gone from
/// FleetView altogether — back to the open panel and the folder tree to find it again. Projects
/// still on the board are listed too, tagged: "what was I working on" has the same answer whether
/// or not you have put it away, and a click takes you to it either way.
struct RecentProjectsPopover: View {
    @EnvironmentObject var state: AppState
    let close: () -> Void

    @State private var query = ""
    /// Read once when the popover opens. Nothing in it moves while you are choosing, and a list
    /// that re-sorted under the pointer would be worse than one a minute out of date.
    @State private var rows: [RecentProjectRow] = []
    @FocusState private var filterFocused: Bool

    /// Ten rows, then scroll. The list gets a definite height worked out from its rows: a popover
    /// takes its content's ideal size, a ScrollView has none of its own, and with only a
    /// `maxHeight` the first build opened as a one-row sliver with the rest scrolled out of sight.
    static let rowHeight: CGFloat = 46
    private static let rowGap: CGFloat = 2
    private static let rowsShown = 10
    private static let listPadding: CGFloat = 8

    static func listHeight(rows: Int) -> CGFloat {
        let n = CGFloat(min(rows, rowsShown))
        return n * rowHeight + max(0, n - 1) * rowGap + 2 * listPadding
    }

    private var shown: [RecentProjectRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 15)).foregroundColor(Theme.primary)
                Text(L(.recentProjTitle)).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                Text("\(rows.count)").font(.fvLabel).foregroundColor(Theme.onSurfaceVariant)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            filterField.padding(.horizontal, 12).padding(.bottom, 10)
            Rectangle().fill(Theme.outlineVariant).frame(height: 1)
            let list = shown
            if list.isEmpty {
                Text(rows.isEmpty ? L(.recentProjEmpty) : L(.recentProjNoMatch))
                    .font(.fvBodySmall).foregroundColor(Theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                TimelineView(.everyMinute) { ctx in
                    ScrollView {
                        LazyVStack(spacing: Self.rowGap) {
                            ForEach(list) { r in
                                RecentProjectRowView(row: r, now: ctx.date,
                                                     open: { open(r) }, openHistory: { openHistory(r) })
                            }
                        }
                        .padding(Self.listPadding)
                    }
                }
                .frame(height: Self.listHeight(rows: list.count))
            }
            Rectangle().fill(Theme.outlineVariant).frame(height: 1)
            Button {
                close()
                DashboardView.pickFolder(into: state)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 13))
                    Text(L(.recentProjOpenFolder)).font(.fvLabel)
                    Spacer()
                }
                .foregroundColor(Theme.onSurfaceVariant)
                .padding(.horizontal, 16).frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 420)
        .background(Theme.panel)
        .onAppear {
            rows = state.recentProjectRows()
            filterFocused = true
        }
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Theme.onSurfaceVariant)
            TextField(L(.recentProjFilter), text: $query)
                .textFieldStyle(.plain).font(.fvBody)
                .focused($filterFocused)
                // Return takes the top match: filter, then go, without reaching for the pointer.
                .onSubmit { if let first = shown.first { open(first) } }
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(Theme.surfaceContainerHigh).clipShape(Capsule())
    }

    /// `addProject` is open-or-go: it dedupes by path, selects the project and scrolls the board to
    /// it, so the row needs no "already open?" branch of its own.
    private func open(_ r: RecentProjectRow) {
        close()
        state.addProject(path: r.path)
    }

    /// The drawer the count describes. It lists a project's removed cards by the project on the
    /// board, so a closed project is opened first — which is also where a restored card lands.
    private func openHistory(_ r: RecentProjectRow) {
        close()
        state.addProject(path: r.path)
        if let id = state.projects.first(where: { $0.path == r.path })?.id {
            state.openArchive(projectId: id)
        }
    }
}

private struct RecentProjectRowView: View {
    let row: RecentProjectRow
    let now: Date
    let open: () -> Void
    let openHistory: () -> Void
    @State private var hover = false

    private var shortPath: String {
        let home = FV.home.path
        return row.path.hasPrefix(home + "/") ? "~" + row.path.dropFirst(home.count) : row.path
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.projectId != nil ? "folder.fill" : "folder")
                .font(.system(size: 14))
                .foregroundColor(row.projectId != nil ? Theme.primary : Theme.onSurfaceVariant)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).font(.fvTitleSmall).foregroundColor(Theme.onSurface).lineLimit(1)
                    if row.projectId != nil {
                        Text(L(.recentProjOnBoard)).font(.fvLabelSmall)
                            .foregroundColor(Theme.onPrimaryContainer)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.primaryContainer).clipShape(Capsule())
                    }
                }
                Text(shortPath).font(.fvMono).foregroundColor(Theme.onSurfaceVariant)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if row.history > 0 {
                Button(action: openHistory) {
                    HStack(spacing: 4) {
                        Image(systemName: "archivebox").font(.system(size: 12))
                        Text("\(row.history)").font(.fvLabel).monospacedDigit()
                    }
                    .foregroundColor(Theme.onSurfaceVariant)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Theme.surfaceContainerHighest).clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L(.projArchived(row.history)))
            }
            Text(row.lastUsed.map { RelativeTime.compact($0, now: now) } ?? "—")
                .font(.fvLabel).monospacedDigit().foregroundColor(Theme.onSurfaceVariant)
                .frame(minWidth: 34, alignment: .trailing)
                .help(row.lastUsed.map {
                    L(.recentProjLastUsed($0.formatted(date: .abbreviated, time: .shortened)))
                } ?? L(.recentProjNever))
        }
        .padding(.horizontal, 10).frame(height: RecentProjectsPopover.rowHeight)
        .background(hover ? Theme.surfaceContainerHigh : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .help(row.path)
    }
}
