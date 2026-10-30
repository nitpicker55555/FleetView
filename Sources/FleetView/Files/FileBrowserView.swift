import AppKit
import FleetViewFiles
import SwiftUI

/// The file window: the tree on the left, tabs and the editor on the right.
struct FileBrowserView: View {
    @ObservedObject var model: FileBrowserModel
    @State private var sidebarWidth: CGFloat = 270

    var body: some View {
        HStack(spacing: 0) {
            if !model.sidebarHidden {
                FileSidebar(model: model)
                    .frame(width: sidebarWidth)
                FileSidebarDivider(width: $sidebarWidth) { model.sidebarHidden = true }
            }
            VStack(spacing: 0) {
                FileTabBar(model: model)
                if model.active != nil { FileToolbar(model: model) }
                if let id = model.activeTab, let banner = model.banners[id] { FileBanner(model: model, id: id, banner: banner) }
                ZStack {
                    EditorHostView(bridge: model.editor)
                    if model.tabs.isEmpty { emptyState }
                }
                FileStatusBar(model: model)
            }
        }
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t).font(.fvBodySmall).foregroundColor(Theme.inverseOnSurface)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.inverseSurface).clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 40).transition(.opacity)
            }
        }
        .overlay { FileShortcuts(model: model) }
        .overlay(alignment: .top) {
            if model.quickOpen { QuickOpenPanel(model: model).padding(.top, 48) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 28)).foregroundColor(Theme.outline)
            Text(L(.filesEmpty)).font(.fvBody).foregroundColor(Theme.subtext)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

/// Keyboard shortcuts that belong to the window. The page binds the same keys while the editor has
/// focus; the model treats two arrivals of one press as one.
private struct FileShortcuts: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        ZStack {
            Button("") { model.key("save") }.keyboardShortcut("s", modifiers: .command)
            Button("") { model.key("closeTab") }.keyboardShortcut("w", modifiers: .command)
            Button("") { model.key("copyPath") }.keyboardShortcut("c", modifiers: [.command, .option])
            Button("") { model.key("quickOpen") }.keyboardShortcut("p", modifiers: .command)
            Button("") { model.key("searchFiles") }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("") { model.key("back") }.keyboardShortcut("-", modifiers: .control)
            Button("") { model.key("forward") }.keyboardShortcut("-", modifiers: [.control, .shift])
            // The system's own key for a sidebar (View › Hide Sidebar).
            Button("") { model.sidebarHidden.toggle() }.keyboardShortcut("s", modifiers: [.command, .control])
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
    }
}

private struct FileSidebarDivider: View {
    @Binding var width: CGFloat
    /// Dragged well past the narrowest the sidebar goes: it is put away, as a split view does it.
    let collapse: () -> Void
    @State private var start: CGFloat?
    /// Pushes and pops must pair: an unpaired pop takes the cursor of whatever pushed before us.
    @State private var pushed = false

    var body: some View {
        Rectangle().fill(Theme.outlineVariant).frame(width: 1)
            .overlay(Color.clear.frame(width: 7).contentShape(Rectangle())
                .onHover { inside in
                    if inside && !pushed { NSCursor.resizeLeftRight.push(); pushed = true }
                    if !inside && pushed { NSCursor.pop(); pushed = false }
                }
                .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if start == nil { start = width }
                        let wanted = (start ?? width) + g.translation.width
                        width = min(520, max(180, wanted))
                        if wanted < 110 { start = nil; collapse() }
                    }
                    .onEnded { _ in start = nil }))
    }
}

// MARK: - Sidebar

struct FileSidebar: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(model.projectName).font(.fvTitleSmall).foregroundColor(Theme.text).lineLimit(1)
                if let b = model.branch {
                    Text("⎇ " + b).font(.fvMono).foregroundColor(Theme.subtext).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { model.sidebarHidden = true } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 12)).foregroundColor(Theme.subtext)
                }
                .buttonStyle(.borderless).help(L(.filesHideSidebar))
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Picker("", selection: $model.sideMode) {
                Text(L(.filesTabFiles)).tag(FileBrowserModel.SideMode.tree)
                Text(L(.filesTabSearch)).tag(FileBrowserModel.SideMode.search)
                Text(L(.filesTabHistory)).tag(FileBrowserModel.SideMode.history)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .padding(.horizontal, 10).padding(.bottom, 6)
            if model.sideMode == .tree {
                SidebarField(text: $model.filter, placeholder: L(.filesFilterPlaceholder), icon: "line.3.horizontal.decrease")
                if model.repo != nil && model.filter.isEmpty {
                    Toggle(isOn: $model.showIgnored) {
                        Text(L(.filesShowIgnored)).font(.fvBodySmall).foregroundColor(Theme.subtext)
                    }
                    .toggleStyle(.checkbox).controlSize(.small)
                    .padding(.horizontal, 12).padding(.bottom, 6)
                }
                Divider().overlay(Theme.outlineVariant)
                if model.filter.isEmpty {
                    if !model.recent.isEmpty { RecentSection(model: model) }
                    FileTree(model: model)
                } else {
                    FilterResults(model: model)
                }
            } else if model.sideMode == .search {
                SearchPane(model: model)
            } else {
                HistoryPane(model: model)
            }
        }
        .background(Theme.panel)
    }
}

struct SidebarField: View {
    @Binding var text: String
    let placeholder: String
    let icon: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(Theme.outline)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.fvBodySmall).onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Theme.outline) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.outlineVariant))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }
}

struct FilterResults: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(L(.filesFilterCount(model.filterResults.count))).font(.fvLabelSmall).foregroundColor(Theme.outline)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                ForEach(model.filterResults, id: \.self) { p in
                    PathRow(path: p, selected: model.active?.path == p)
                        .contentShape(Rectangle())
                        .onTapGesture { model.open(p.hasSuffix("/") ? String(p.dropLast()) : p) }
                        .contextMenu { FileContextMenu(model: model, rel: p, isDir: p.hasSuffix("/")) }
                }
            }
        }
    }
}

/// A file as name and folder, the folder dimmed.
struct PathRow: View {
    let path: String
    var selected = false
    var bold: Set<Int> = []

    var body: some View {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let cut = trimmed.lastIndex(of: "/").map { trimmed.index(after: $0) } ?? trimmed.startIndex
        let nameStart = trimmed.distance(from: trimmed.startIndex, to: cut)
        HStack(spacing: 6) {
            FileIcon(name: trimmed, isDir: path.hasSuffix("/"))
            Self.marked(String(trimmed[cut...]), offset: nameStart, bold: bold).font(.system(size: 12.5)).foregroundColor(Theme.text).lineLimit(1)
            Self.marked(String(trimmed[..<cut]), offset: 0, bold: bold).font(.fvLabelSmall).foregroundColor(Theme.outline)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: 24)
        .background(selected ? Theme.secondaryContainer : Color.clear)
    }

    /// `text` with the characters at `bold` (offsets into the whole path) in the accent colour.
    static func marked(_ text: String, offset: Int, bold: Set<Int>) -> Text {
        guard !bold.isEmpty else { return Text(text) }
        var out = Text("")
        for (i, ch) in text.enumerated() {
            let t = Text(String(ch))
            out = out + (bold.contains(offset + i) ? t.foregroundColor(Theme.primary).bold() : t)
        }
        return out
    }
}

struct SearchPane: View {
    @ObservedObject var model: FileBrowserModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(Theme.outline)
                TextField(L(.filesSearchPlaceholder), text: $model.searchQuery).textFieldStyle(.plain).font(.fvBodySmall)
                    .focused($focused).onSubmit { model.runSearch() }
                Toggle(isOn: $model.searchCaseSensitive) { Text("Aa").font(.fvLabelSmall) }
                    .toggleStyle(.button).controlSize(.mini).help(L(.filesSearchCase))
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.outlineVariant))
            .padding(.horizontal, 10).padding(.bottom, 6)
            Text(summary).font(.fvLabelSmall).foregroundColor(Theme.outline).padding(.horizontal, 12).padding(.bottom, 4)
            Divider().overlay(Theme.outlineVariant)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.searchResults) { g in
                        PathRow(path: g.path).contentShape(Rectangle())
                            .onTapGesture { if let h = g.hits.first { model.openHit(h) } }
                        ForEach(Array(g.hits.prefix(20).enumerated()), id: \.offset) { _, h in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(h.line)").font(.fvMono).foregroundColor(Theme.outline).frame(minWidth: 28, alignment: .trailing)
                                Text(h.text).font(.fvMono).foregroundColor(Theme.subtext).lineLimit(1)
                            }
                            .padding(.leading, 18).padding(.trailing, 10).frame(height: 20)
                            .contentShape(Rectangle())
                            .onTapGesture { model.openHit(h) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { focused = true }
        .onChange(of: model.searchCaseSensitive) { model.runSearch() }
    }

    private var summary: String {
        switch model.searchState {
        case .idle: return L(.filesSearchHint)
        case .running: return L(.filesSearching)
        case .done(let m, let f, let cut):
            if m == 0 { return L(.filesSearchNone) }
            return L(.filesSearchSummary(m, f)) + (cut ? " · " + L(.filesSearchTruncated) : "")
        }
    }
}

struct QuickOpenPanel: View {
    @ObservedObject var model: FileBrowserModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.outline)
                TextField(L(.filesQuickOpenPlaceholder), text: $model.quickQuery)
                    .textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                    .onSubmit { model.quickPick() }
                    .onKeyPress(.downArrow) { model.quickMove(1); return .handled }
                    .onKeyPress(.upArrow) { model.quickMove(-1); return .handled }
                    .onKeyPress(.escape) { model.quickOpen = false; return .handled }
            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider().overlay(Theme.outlineVariant)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.quickQuery.isEmpty && !model.quickResults.isEmpty {
                            Text(L(.filesQuickOpenRecent)).font(.fvLabelSmall).foregroundColor(Theme.outline)
                                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
                        }
                        ForEach(Array(model.quickResults.enumerated()), id: \.element.path) { i, m in
                            PathRow(path: m.path, selected: i == model.quickSelection, bold: Set(m.positions))
                                .contentShape(Rectangle())
                                .onTapGesture { model.quickPick(i) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.quickSelection) { _, i in
                    if model.quickResults.indices.contains(i) { proxy.scrollTo(model.quickResults[i].path) }
                }
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 580)
        .background(Theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.outlineVariant))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onAppear { focused = true }
        .onExitCommand { model.quickOpen = false }
    }
}

struct FileTree: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        FileTreeRow(model: model, row: row, selected: model.selected == row.id,
                                    mark: model.marks[row.id], expanded: model.expanded.contains(row.id),
                                    dirtyDir: row.isDir && model.dirtyDirs.contains(row.id),
                                    branch: row.isDir ? model.nestedBranches[row.id] : nil)
                            .id(row.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.revealTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .center) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.revealTarget = nil }
            }
        }
    }
}

/// One row of the tree. What it shows comes in as values and the model is held only for its
/// actions, not observed: a row is drawn again when its own values change, not whenever anything in
/// the window does.
struct FileTreeRow: View {
    let model: FileBrowserModel
    let row: FileBrowserModel.Row
    let selected: Bool
    let mark: GitStatus.Mark?
    let expanded: Bool
    let dirtyDir: Bool
    /// A repository inside the project starts here: its branch.
    var branch: String? = nil
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if row.isDir {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            .foregroundColor(Theme.outline)
            FileIcon(name: row.name, isDir: row.isDir)
            Text(row.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                .foregroundColor(textColor)
            if let branch {
                Text("⎇ " + branch).font(.fvMono).foregroundColor(Theme.outline).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let mark {
                Text(mark.rawValue).font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Self.color(mark))
            } else if dirtyDir {
                Circle().fill(Theme.warn).frame(width: 5, height: 5)
            }
        }
        .padding(.leading, CGFloat(8 + row.depth * 14)).padding(.trailing, 10)
        .frame(height: 23)
        .background(selected ? Theme.secondaryContainer : (hover ? Theme.surfaceContainerHigh : Color.clear))
        .opacity(row.ignored ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .gesture(TapGesture(count: 1).onEnded {
            if row.isDir {
                // The second click of a double-click arrives as a click too: it must not close the
                // folder the first one opened.
                if (NSApp.currentEvent?.clickCount ?? 1) < 2 { model.toggle(row.id) }
            } else {
                model.open(row.id)
            }
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !row.isDir { model.open(row.id, pin: true) } })
        .contextMenu { FileContextMenu(model: model, rel: row.id, isDir: row.isDir) }
        .help(row.id)
    }

    private var textColor: Color {
        if mark == .deleted { return Theme.outline }
        return selected ? Theme.onSecondaryContainer : Theme.text
    }

    static func color(_ m: GitStatus.Mark) -> Color {
        switch m {
        case .modified, .renamed: return Theme.warn
        case .added, .untracked: return Theme.primary
        case .deleted, .conflicted: return Theme.error
        }
    }
}

struct FileIcon: View {
    let name: String
    let isDir: Bool

    var body: some View {
        Image(systemName: symbol).font(.system(size: 11.5)).foregroundColor(tint).frame(width: 15)
    }

    private var ext: String { (name as NSString).pathExtension.lowercased() }

    private var symbol: String {
        if isDir { return "folder" }
        if FileBrowserModel.imageExtensions.contains(ext) { return "photo" }
        switch ext {
        case "md", "markdown", "txt": return "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "xml", "resolved": return "curlybraces"
        case "sh", "zsh", "bash": return "terminal"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tgz", "xz", "7z", "dmg": return "archivebox"
        default: return "doc"
        }
    }

    private var tint: Color {
        if isDir { return Theme.outline }
        switch ext {
        case "swift": return Color(red: 0.94, green: 0.53, blue: 0.24)
        case "py": return Color(red: 0.42, green: 0.71, blue: 1)
        case "js", "ts", "tsx", "jsx", "mjs": return Color(red: 0.95, green: 0.83, blue: 0.35)
        case "md", "markdown": return Color(red: 0.56, green: 0.81, blue: 1)
        default: return Theme.outline
        }
    }
}

struct FileContextMenu: View {
    @ObservedObject var model: FileBrowserModel
    let rel: String
    let isDir: Bool

    var body: some View {
        if !isDir {
            Button(L(.filesOpen)) { model.open(rel, pin: true) }
            Divider()
        }
        if model.repoFor(rel) != nil {
            Button(isDir ? L(.histFolderHistory) : L(.histFileHistory)) { model.showHistory(of: rel) }
            Divider()
        }
        Button(L(.filesCopyPath) + "  ⌥⌘C") { model.copyPath(rel) }
        Button(L(.filesCopyRelative)) { model.copyPath(rel, relativeOnly: true) }
        Button(L(.filesReveal)) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.absolute(rel))]) }
        if !isDir {
            // Not for programs and scripts: "open" would run them.
            if FileBrowserModel.safeToOpen(model.absolute(rel)) {
                Button(L(.filesOpenDefault)) { NSWorkspace.shared.open(URL(fileURLWithPath: model.absolute(rel))) }
            }
            Divider()
            ReferenceMenu(model: model, rel: rel)
        }
    }
}

struct ReferenceMenu: View {
    @ObservedObject var model: FileBrowserModel
    let rel: String

    var body: some View {
        Menu(L(.filesReference)) { ReferenceItems(model: model, rel: rel) }
    }
}

/// The project's open terminals, one item each.
struct ReferenceItems: View {
    @ObservedObject var model: FileBrowserModel
    let rel: String

    var body: some View {
        let targets = model.referenceTargets
        if targets.isEmpty {
            Text(L(.filesReferenceNone))
        } else {
            ForEach(targets) { t in
                Button("\(t.name)  ·  \(t.agentKind == .claude ? "@" : "")\((rel as NSString).lastPathComponent)") {
                    model.reference(rel, in: t)
                }
            }
        }
    }
}

// MARK: - Tabs

struct FileTabBar: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        HStack(spacing: 0) {
            // With the sidebar put away, the way back is where it was: the window's top left.
            if model.sidebarHidden {
                Button { model.sidebarHidden = false } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 12)).foregroundColor(Theme.subtext)
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L(.filesShowSidebar))
                Rectangle().fill(Theme.outlineVariant).frame(width: 1, height: 34)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tabs) { tab in FileTabView(model: model, tab: tab) }
                }
            }
        }
        .frame(height: 34)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.outlineVariant).frame(height: 1) }
    }
}

struct FileTabView: View {
    @ObservedObject var model: FileBrowserModel
    let tab: FileBrowserModel.Tab
    @State private var hover = false

    private var on: Bool { model.activeTab == tab.id }

    var body: some View {
        HStack(spacing: 6) {
            if let c = tab.changes {
                Image(systemName: c.sha != nil ? "clock.arrow.circlepath" : "plusminus").font(.system(size: 11.5))
                    .foregroundColor(Theme.primary).frame(width: 15)
            } else {
                FileIcon(name: tab.path, isDir: false)
            }
            Text(tab.changes.map { String($0.title.prefix(28)) } ?? (tab.path as NSString).lastPathComponent)
                .font(.system(size: 12.5)).italic(!tab.pinned).lineLimit(1)
                .foregroundColor(on ? Theme.text : Theme.subtext)
            ZStack {
                if tab.dirty && !hover {
                    Circle().fill(Theme.onSurfaceVariant).frame(width: 7, height: 7)
                } else {
                    Button { model.close(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Theme.outline).frame(width: 16, height: 16)
                            .background(hover ? Theme.surfaceContainerHighest : Color.clear).clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain).opacity(hover || on ? 1 : 0)
                }
            }
            .frame(width: 16)
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 34)
        .background(on ? Theme.bg : Color.clear)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.outlineVariant).frame(width: 1) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .gesture(TapGesture(count: 1).onEnded { model.activate(tab.id) })
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.pin(tab.id) })
        .help((tab.changes?.title ?? tab.path) + (tab.pinned ? "" : "  " + L(.filesPreviewTabHelp)))
    }
}

// MARK: - Toolbar

struct FileToolbar: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        if let tab = model.active {
            HStack(spacing: 6) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).disabled(!model.canGoBack).help(L(.filesBack) + "  ⌃-")
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).disabled(!model.canGoForward).help(L(.filesForward) + "  ⌃⇧-")
                Button { model.showQuickOpen() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help(L(.filesQuickOpen) + "  ⌘P")
                if let c = tab.changes {
                    Text(c.title).font(.fvBodySmall).foregroundColor(Theme.text).lineLimit(1)
                    Spacer(minLength: 8)
                } else {
                breadcrumbs(tab.path)
                Spacer(minLength: 8)
                if tab.kind == .text {
                    if model.docLang(tab.id) == "markdown" {
                        Picker("", selection: Binding(get: { tab.mode }, set: { model.setMode(tab.id, $0) })) {
                            Text(L(.filesPreview)).tag(FileBrowserModel.Mode.preview)
                            Text(L(.filesSource)).tag(FileBrowserModel.Mode.source)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                    }
                    if tab.mode == .source {
                        toolButton(L(.filesWrap), on: tab.wrap) { model.toggleWrap(tab.id) }
                        toolButton(L(.filesGotoLine)) { model.editor.call("gotoPrompt") }
                    }
                }
                Menu {
                    ReferenceItems(model: model, rel: tab.path)
                } label: {
                    Label(L(.filesReference), systemImage: "arrow.up.right")
                }
                .menuStyle(.borderlessButton).fixedSize().font(.fvLabel)
                Button { model.copyPath(tab.path) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(L(.filesCopyPath) + "  ⌥⌘C")
                Menu {
                    FileContextMenu(model: model, rel: tab.path, isDir: false)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.outlineVariant).frame(height: 1) }
            .background(Theme.bg)
        }
    }

    private func breadcrumbs(_ rel: String) -> some View {
        let parts = rel.split(separator: "/").map(String.init)
        return HStack(spacing: 2) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Text("›").font(.fvBodySmall).foregroundColor(Theme.outline) }
                Text(part).font(.fvBodySmall).lineLimit(1)
                    .foregroundColor(i == parts.count - 1 ? Theme.text : Theme.subtext)
                    .onTapGesture {
                        let dir = parts.prefix(i + 1).joined(separator: "/")
                        if i < parts.count - 1 { model.reveal(dir + "/"); if !model.expanded.contains(dir) { model.toggle(dir) } }
                    }
            }
        }
        .lineLimit(1)
    }

    private func toolButton(_ title: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.fvLabel)
                .foregroundColor(on ? Theme.onSecondaryContainer : Theme.subtext)
                .padding(.horizontal, 8).frame(height: 24)
                .background(on ? Theme.secondaryContainer : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Banner

struct FileBanner: View {
    @ObservedObject var model: FileBrowserModel
    let id: String
    let banner: FileBrowserModel.Banner

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12))
            Text(text).font(.fvBodySmall).lineLimit(2)
            Spacer(minLength: 8)
            buttons
        }
        .foregroundColor(Theme.onPrimaryContainer)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(warn ? Theme.warnContainer : Theme.primaryContainer)
    }

    private var warn: Bool {
        switch banner { case .diskChanged, .deleted, .failed: return true; default: return false }
    }

    private var icon: String {
        switch banner {
        case .diskChanged: return "exclamationmark.triangle"
        case .deleted: return "trash"
        case .failed: return "xmark.octagon"
        case .recovered, .crashRestored: return "arrow.uturn.backward"
        }
    }

    private var text: String {
        switch banner {
        case .diskChanged: return L(.filesDiskChanged)
        case .deleted: return L(.filesDeleted)
        case .failed(let why): return L(.filesSaveFailed(why))
        case .recovered(let at, let same):
            return L(.filesRecovered(RelativeTime.compact(at, now: Date()))) + (same ? "" : " " + L(.filesRecoveredOld))
        case .crashRestored: return L(.filesCrashRestored)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch banner {
        case .diskChanged:
            bannerButton(L(.filesUseDisk)) { model.useDiskVersion(id) }
            bannerButton(L(.filesCompare)) { model.compare(id) }
            bannerButton(L(.filesOverwrite)) { model.overwrite(id) }
        case .deleted:
            bannerButton(L(.filesCloseTab)) { model.close(id) }
        case .failed:
            bannerButton(L(.filesGotIt)) { model.dismissBanner(id) }
        case .recovered:
            bannerButton(L(.filesRestore)) { model.restoreRecovered(id) }
            bannerButton(L(.filesDiscard)) { model.discardRecovered(id) }
        case .crashRestored:
            bannerButton(L(.filesGotIt)) { model.dismissBanner(id) }
        }
    }

    private func bannerButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.fvLabel).padding(.horizontal, 9).frame(height: 22)
                .background(Color.white.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status bar

struct FileStatusBar: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        HStack(spacing: 14) {
            if let tab = model.active {
                if tab.kind == .text {
                    Text(Self.langName(model.docLang(tab.id)))
                    if let eol = model.docEOL(tab.id) { Text(eol) }
                    CursorInfo(bar: model.statusBar)
                    if let reason = tab.readOnly { Text(L(.filesReadOnly(Self.reason(reason)))).foregroundColor(Theme.warn) }
                }
                if let size = model.docSize(tab.id) { Text(FileBrowserModel.sizeText(size)) }
                Spacer(minLength: 0)
                DiffInfo(bar: model.statusBar)
                if let m = model.marks[tab.path] {
                    Text(Self.markName(m)).foregroundColor(FileTreeRow.color(m))
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(.fvLabelSmall).foregroundColor(Theme.outline).lineLimit(1)
        .padding(.horizontal, 12).frame(height: 24)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.outlineVariant).frame(height: 1) }
    }

    static func langName(_ id: String) -> String {
        let names = ["markdown": "Markdown", "swift": "Swift", "python": "Python", "javascript": "JavaScript", "jsx": "JSX",
                     "typescript": "TypeScript", "tsx": "TSX", "json": "JSON", "html": "HTML", "xml": "XML", "css": "CSS",
                     "yaml": "YAML", "toml": "TOML", "shell": "Shell", "rust": "Rust", "go": "Go", "cpp": "C / C++",
                     "java": "Java", "sql": "SQL", "ruby": "Ruby", "lua": "Lua", "diff": "Diff", "properties": "Config",
                     "dockerfile": "Dockerfile"]
        return names[id] ?? L(.filesPlainText)
    }

    static func reason(_ r: String) -> String {
        switch r {
        case FileText.ReadOnly.mixedLineEndings.rawValue: return L(.filesROMixed)
        case FileText.ReadOnly.notWritable.rawValue: return L(.filesRONotWritable)
        case FileText.ReadOnly.notRoundTrip.rawValue: return L(.filesRONotRoundTrip)
        default: return r
        }
    }

    static func markName(_ m: GitStatus.Mark) -> String {
        switch m {
        case .modified: return L(.filesMarkModified)
        case .added: return L(.filesMarkAdded)
        case .deleted: return L(.filesMarkDeleted)
        case .renamed: return L(.filesMarkRenamed)
        case .untracked: return L(.filesMarkUntracked)
        case .conflicted: return L(.filesMarkConflicted)
        }
    }
}

/// Line and column: the part of the status bar that changes as the cursor moves.
private struct CursorInfo: View {
    @ObservedObject var bar: FileStatusModel

    var body: some View {
        if bar.status.lines > 0 {
            Text(L(.filesCursor(bar.status.line, bar.status.col)))
            Text(L(.filesLines(bar.status.lines)))
        }
    }
}

private struct DiffInfo: View {
    @ObservedObject var bar: FileStatusModel

    var body: some View {
        if bar.status.hasDiff && !bar.status.noHead {
            Text(L(.filesDiffStats(bar.status.added, bar.status.changed, bar.status.deleted)))
        }
    }
}

/// The files that changed lately, above the tree.
struct RecentSection: View {
    @ObservedObject var model: FileBrowserModel
    @State private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(L(.filesRecent)).font(.fvLabelSmall)
                    Spacer()
                }
                .foregroundColor(Theme.outline).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            if open {
                ForEach(model.recent) { r in
                    HStack(spacing: 6) {
                        FileIcon(name: r.path, isDir: false)
                        Text((r.path as NSString).lastPathComponent).font(.system(size: 12.5)).foregroundColor(Theme.text).lineLimit(1)
                        Text((r.path as NSString).deletingLastPathComponent).font(.fvLabelSmall).foregroundColor(Theme.outline)
                            .lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 4)
                        if let by = r.by {
                            Text(by).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                                .foregroundColor(Theme.onPrimaryContainer)
                                .padding(.horizontal, 6).frame(height: 16)
                                .background(Theme.primaryContainer).clipShape(Capsule())
                        }
                        TimelineView(.periodic(from: r.at, by: 30)) { ctx in
                            Text(RelativeTime.compact(r.at, now: ctx.date)).font(.fvLabelSmall).foregroundColor(Theme.outline)
                        }
                    }
                    .padding(.horizontal, 12).frame(height: 23)
                    .background(model.active?.path == r.path ? Theme.secondaryContainer : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(r.path) }
                    .help(r.path)
                }
            }
            Divider().overlay(Theme.outlineVariant).padding(.top, 4)
        }
    }
}
