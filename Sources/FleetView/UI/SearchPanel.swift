import SwiftUI
import AppKit

/// Search across every local Claude and Codex conversation. Opens over the board (⌘K) rather than
/// docking beside a terminal, because a hit can come from any project — including one that has no
/// terminal open right now.
struct SearchPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider().overlay(Theme.stroke)
            scopeBar
            Divider().overlay(Theme.stroke)
            results
            Divider().overlay(Theme.stroke)
            footer
        }
        // The recede goes on the CONTENT, inside the panel's own shape. Applied after `clipShape` it
        // blurred the clipped result — so the rounded edge and the border smeared, and the blur
        // sampled the transparency outside the shape and faded the whole rim out. A panel that
        // recedes should keep its chrome crisp and push only what is inside it back.
        .receded(model.preview != nil)
        .frame(width: 780, height: 560)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
        .overlay { previewCard }
        // Esc peels one layer at a time: the preview first, then the panel.
        .onExitCommand { model.preview != nil ? model.closePreview() : state.closeSearch() }
        // Tab widens the search a step. It has to be intercepted here rather than bound as a
        // shortcut: the field has focus, and Tab is what SwiftUI would otherwise use to leave it.
        .background {
            Button("") { model.mode = model.mode.next }
                .keyboardShortcut(.tab, modifiers: []).hidden()
        }
        .onAppear {
            model.app = state
            focused = true
            model.refreshIndex()
        }
    }

    // MARK: - Search field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.subtext).font(.system(size: 14, weight: .medium))
            TextField("搜索所有对话历史…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundColor(Theme.text)
                .focused($focused)
                .onSubmit { openFirst() }
            if model.indexing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.subtext)
                }.buttonStyle(.plain).help("清除")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    // MARK: - Scope

    /// How wide to look (Tab), and — once you are in the conversation tiers — which side and which
    /// agent. The scope pills are hidden in fleet mode because they mean nothing there.
    private var scopeBar: some View {
        HStack(spacing: 6) {
            ForEach(SearchModel.Mode.allCases) { m in
                segment(m.title, on: model.mode == m) { model.mode = m }
            }
            Text("⇥")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.subtext.opacity(0.7))
                .padding(.leading, 1)

            if model.mode != .fleet {
                Divider().frame(height: 16).overlay(Theme.stroke).padding(.horizontal, 4)
                segment("我的 prompt", on: model.scope == .prompts) { model.scope = .prompts }
                segment("Agent 回复", on: model.scope == .replies) { model.scope = .replies }
                segment("全部", on: model.scope == .both) { model.scope = .both }
                segment("Claude", on: model.source == .claude, tint: Theme.claudeTint) {
                    model.source = model.source == .claude ? nil : .claude
                }
                segment("Codex", on: model.source == .codex, tint: Theme.codexTint) {
                    model.source = model.source == .codex ? nil : .codex
                }
            }
            Spacer()
            if model.total > 0 {
                Text(String(format: "%d 项 · %d 个项目 · %.0f ms",
                            model.total, model.projectGroups.count, model.elapsed))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(Theme.subtext)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func segment(_ title: String, on: Bool, tint: Color = Theme.accent,
                         _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundColor(on ? Theme.onAccent : Theme.subtext)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(on ? tint : Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }

    // MARK: - Results

    @ViewBuilder private var results: some View {
        if let failure = model.failure {
            message(failure, icon: "exclamationmark.triangle", tint: Theme.amber)
        } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message(model.indexing ? model.indexNote : "", icon: "text.magnifyingglass",
                    tint: Theme.subtext)
        } else if model.projectGroups.isEmpty {
            message(model.indexing ? model.indexNote : "", icon: "questionmark.circle",
                    tint: Theme.subtext)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.projectGroups) { p in
                        projectSection(p)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
    }

    /// A project, its count, and — when it is the focused one — what matched inside it. Collapsed by
    /// default with more than one project: the first question is which project, and answering that
    /// before showing hits is the difference between choosing and scrolling.
    @ViewBuilder private func projectSection(_ p: SearchModel.ProjectGroup) -> some View {
        let open = model.focusedProject == p.id
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.focusedProject = open ? nil : p.id
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundColor(Theme.subtext)
                        .frame(width: 10)
                    Image(systemName: "folder")
                        .font(.system(size: 10)).foregroundColor(Theme.accent)
                    Text(p.name)
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text)
                    Text("\(p.count)")
                        .font(.system(size: 9.5, weight: .semibold)).foregroundColor(Theme.subtext)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Theme.card).clipShape(Capsule())
                    if !open && !p.sessions.isEmpty {
                        Text("\(p.sessions.count) 个会话")
                            .font(.system(size: 10)).foregroundColor(Theme.subtext.opacity(0.8))
                    }
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(p.fleet) { fleetRow($0) }
                    ForEach(p.sessions) { groupCard($0) }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .background(Theme.card.opacity(0.32))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke, lineWidth: 1))
    }

    /// A project / cluster / terminal from the board. `why` is shown because a hit on an id or a cwd
    /// is otherwise inexplicable — the name on screen won't contain what you typed.
    private func fleetRow(_ h: SearchModel.FleetHit) -> some View {
        let tint: Color = h.kind == .terminal
            ? (h.status.map { Theme.statusColor($0) } ?? Theme.subtext)
            : Theme.accent
        return Button {
            if h.kind == .terminal {
                state.raiseTerminal(h.id)
                state.closeSearch()
            } else if let pid = h.projectId {
                state.selectedProjectId = pid
                state.closeSearch()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: h.kind == .terminal ? "terminal"
                      : (h.kind == .cluster ? "rectangle.stack" : "folder"))
                    .font(.system(size: 11)).foregroundColor(tint).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(highlighted(h.name, base: Theme.text))
                            .font(.system(size: 12, weight: .semibold))
                        if let c = h.clusterName {
                            Text(c).font(.system(size: 9)).foregroundColor(Theme.subtext)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Theme.card).clipShape(Capsule())
                        }
                        if let a = h.agent, a != .unknown {
                            Text(a.label).font(.system(size: 9))
                                .foregroundColor(Theme.agentColor(a))
                        }
                        Text(h.why).font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(Theme.subtext.opacity(0.7))
                    }
                    Text(highlighted(h.detail, base: Theme.subtext))
                        .font(.system(size: 10.5))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9)).foregroundColor(Theme.subtext.opacity(0.45))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(h.kind == .terminal ? "跳到这个终端" : "切到这个项目")
    }

    private func message(_ text: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 26)).foregroundColor(tint.opacity(0.6))
            if !text.isEmpty {
                Text(text).font(.system(size: 12)).foregroundColor(Theme.subtext)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    /// One transcript and everything that matched inside it.
    private func groupCard(_ group: SearchModel.Group) -> some View {
        let tint = group.src == .claude ? Theme.claudeTint : Theme.codexTint
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(projectName(group.project))
                    .font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.text)
                Text(group.src == .claude ? "claude" : "codex")
                    .font(.system(size: 9, weight: .medium)).foregroundColor(tint)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(tint.opacity(0.14)).clipShape(Capsule())
                Spacer()
                Text(shortDate(group.when))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.subtext)
                Text("\(group.hits.count)")
                    .font(.system(size: 9.5, weight: .semibold)).foregroundColor(Theme.subtext)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Theme.card).clipShape(Capsule())
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)

            ForEach(group.hits) { hit in
                hitRow(hit, tint: tint)
            }
        }
        .background(Theme.card.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke, lineWidth: 1))
    }

    private func hitRow(_ hit: SearchIndex.Hit, tint: Color) -> some View {
        let isPrompt = hit.role == .user
        // Reads, not resumes — see SearchModel.showPreview.
        return Button { model.showPreview(hit) } label: {
            HStack(alignment: .top, spacing: 8) {
                // Which side matched is the thing you scan for, so it gets a fixed-width chip
                // rather than being implied by indentation.
                Text(isPrompt ? "我" : "AI")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isPrompt ? Theme.onAccent : tint)
                    .frame(width: 18, height: 14)
                    .background(isPrompt ? Theme.accent : tint.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.top, 1)

                Text(highlighted(snippet(hit.body), base: isPrompt ? Theme.text : Theme.subtext))
                    .font(.system(size: 11.5))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9)).foregroundColor(Theme.subtext.opacity(0.45))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(dragToBoard(hit))
        .help("点击查看上下文（只读）· 拖到终端区域打开")
    }

    /// Drag a result onto the board to open it — the same gesture the tree panel uses, in the
    /// same "fleet" coordinate space, so it reuses the board glow and card-highlight rendering.
    /// Dragging is the only path that writes anything; clicking stays read-only.
    private func dragToBoard(_ hit: SearchIndex.Hit) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("fleet"))
            .onChanged { state.searchDragChanged(hit: hit, location: $0.location) }
            .onEnded { state.treeDragEnded(at: $0.location) }
    }

    // MARK: - Preview

    /// A frosted card over the results: the conversation around the hit, read straight from the
    /// index. Nothing is written until "在终端打开" is pressed.
    @ViewBuilder private var previewCard: some View {
        if let preview = model.preview {
            let tint = preview.hit.src == .claude ? Theme.claudeTint : Theme.codexTint
            ZStack {
                // Catcher only — the panel underneath already receded, and a second wash on top of
                // it was what made level 2 look like a different effect from level 1.
                Color.black.opacity(0.001)
                    .onTapGesture { model.closePreview() }
                VStack(spacing: 0) {
                    previewHeader(preview, tint: tint)
                    Divider().overlay(Theme.stroke)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 9) {
                                ForEach(preview.context) { msg in
                                    previewMessage(msg, isHit: msg.id == preview.hit.id, tint: tint)
                                        .id(msg.id)
                                }
                            }
                            .padding(12)
                        }
                        .onAppear { proxy.scrollTo(preview.hit.id, anchor: .center) }
                        // The window paints first and the whole conversation replaces it a moment
                        // later; without this the hit slides off screen exactly when the thing you
                        // clicked finishes loading.
                        .onChange(of: preview.context.count) { _, _ in
                            proxy.scrollTo(preview.hit.id, anchor: .center)
                        }
                    }
                    Divider().overlay(Theme.stroke)
                    previewFooter(preview)
                }
                .frame(width: 700, height: 470)
                .background(.ultraThinMaterial)          // 毛玻璃
                .background(Theme.panel.opacity(0.55))   // keeps text legible over the list
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 26, y: 10)
            }
            .transition(.opacity)
        }
    }

    private func previewHeader(_ preview: SearchModel.Preview, tint: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(projectName(preview.hit.project))
                .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text)
            Text(preview.hit.src == .claude ? "claude" : "codex")
                .font(.system(size: 9, weight: .medium)).foregroundColor(tint)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(tint.opacity(0.14)).clipShape(Capsule())
            Text(shortDate(preview.hit.ts))
                .font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.subtext)
            // How much of the conversation this is. It climbs from the first window to the whole
            // thing a moment after opening, which is also the signal that the load finished.
            Text("\(preview.context.count) 条")
                .font(.system(size: 10)).foregroundColor(Theme.subtext.opacity(0.7))
            Spacer()
            Button { model.closePreview() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.subtext)
            }.buttonStyle(.plain).help("返回结果 (Esc)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func previewMessage(_ msg: SearchIndex.Hit, isHit: Bool, tint: Color) -> some View {
        let isPrompt = msg.role == .user
        return HStack(alignment: .top, spacing: 8) {
            Text(isPrompt ? "我" : "AI")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isPrompt ? Theme.onAccent : tint)
                .frame(width: 18, height: 14)
                .background(isPrompt ? Theme.accent : tint.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.top, 2)
            Text(highlighted(msg.body, base: isHit ? Theme.text : Theme.subtext))
                .font(.system(size: 11.5, design: isPrompt ? .default : .monospaced))
                .textSelection(.enabled)
                .lineLimit(isHit ? nil : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(isHit ? Theme.accent.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(isHit ? Theme.accent.opacity(0.4) : .clear, lineWidth: 1))
    }

    /// The handle you drag out of the preview onto the board. Opening is a drag, never a click,
    /// so the one action that writes a file can't happen by accident while reading.
    private func previewFooter(_ preview: SearchModel.Preview) -> some View {
        HStack(spacing: 10) {
            if let failure = model.failure {
                Text(failure).font(.system(size: 10)).foregroundColor(Theme.amber).lineLimit(1)
            }
            Spacer()
            if model.opening == preview.hit.id {
                ProgressView().controlSize(.small).scaleEffect(0.5)
            }
            Image(systemName: "hand.draw")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.onAccent)
                .frame(width: 30, height: 22)
                .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .gesture(dragToBoard(preview.hit))
                .onHover { $0 ? NSCursor.openHand.push() : NSCursor.pop() }
                .help("拖到主区域开新终端，或拖到某张卡片加入它的 cluster")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // MARK: - Footer

    /// Numbers and icons only — what the index holds, and whether the list was cut short.
    private var footer: some View {
        HStack(spacing: 8) {
            if model.indexing {
                ProgressView().controlSize(.small).scaleEffect(0.55)
                Text(model.indexNote).font(.system(size: 10)).foregroundColor(Theme.subtext)
            } else {
                Image(systemName: "text.bubble").font(.system(size: 9))
                    .foregroundColor(Theme.subtext.opacity(0.7))
                Text("\(model.stats.messages)")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.subtext)
                Image(systemName: "doc.on.doc").font(.system(size: 9))
                    .foregroundColor(Theme.subtext.opacity(0.7))
                Text("\(model.stats.files)")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.subtext)
            }
            if model.truncated {
                Image(systemName: "ellipsis").font(.system(size: 9))
                    .foregroundColor(Theme.amber.opacity(0.9))
                    .help("结果被截断，只返回了前 \(model.total) 条")
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Helpers

    /// Return previews the top result rather than opening it — same reasoning as a click.
    private func openFirst() {
        guard let hit = model.groups.first?.hits.first else { return }
        model.showPreview(hit)
    }

    private func projectName(_ path: String) -> String {
        path == "—" ? "未知项目" : (path as NSString).lastPathComponent
    }

    /// One line, collapsed and windowed onto the first match — a matched prompt is often a wall of
    /// pasted text, and taking the first 240 characters of one regularly showed no match at all.
    private func snippet(_ body: String) -> String {
        let flat = body.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
        let width = 240
        guard flat.count > width else { return flat }
        // Start a little before the match so it has context on both sides rather than opening on it.
        guard let hit = firstMatch(in: flat) else { return String(flat.prefix(width)) + "…" }
        let lead = 60
        var start = flat.index(hit, offsetBy: -lead, limitedBy: flat.startIndex) ?? flat.startIndex
        if flat.distance(from: start, to: flat.endIndex) < width {
            start = flat.index(flat.endIndex, offsetBy: -width)
        }
        let end = flat.index(start, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end]
            + (end < flat.endIndex ? "…" : "")
    }

    /// Where the earliest search term lands in `text`, if any.
    private func firstMatch(in text: String) -> String.Index? {
        SearchIndex.terms(model.query)
            .compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }
            .min()
    }

    /// Mark every term the index matched on. Each term is highlighted independently because that is
    /// what the query means — two words are two AND-ed terms, not one substring.
    private func highlighted(_ text: String, base: Color) -> AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = base
        for term in SearchIndex.terms(model.query) where !term.isEmpty {
            var from = text.startIndex
            while let r = text.range(of: term, options: .caseInsensitive,
                                     range: from..<text.endIndex) {
                if let lo = AttributedString.Index(r.lowerBound, within: a),
                   let hi = AttributedString.Index(r.upperBound, within: a) {
                    a[lo..<hi].foregroundColor = Theme.amber
                    a[lo..<hi].backgroundColor = Theme.amber.opacity(0.18)
                    a[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
                }
                from = r.upperBound
                if from >= text.endIndex { break }
            }
        }
        return a
    }

    private func shortDate(_ iso: String) -> String {
        // "2026-07-29T10:23:30.123Z" → "07-29 10:23"
        guard iso.count >= 16 else { return "" }
        let d = iso.prefix(10).suffix(5)
        let t = iso.dropFirst(11).prefix(5)
        return "\(d) \(t)"
    }
}
