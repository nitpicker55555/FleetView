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
        .frame(width: 780, height: 560)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
        // This panel is level 1, so it recedes under its own level-2 preview by the same numbers
        // the dashboard recedes under it. The preview is added AFTER, so it stays crisp.
        .receded(model.preview != nil)
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
        .overlay { previewCard }
        // Esc peels one layer at a time: the preview first, then the panel.
        .onExitCommand { model.preview != nil ? model.closePreview() : state.closeSearch() }
        .onAppear {
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

    /// Prompt / reply / both, plus which agent. These are the two axes that actually change what
    /// comes back; everything else is ranking.
    private var scopeBar: some View {
        HStack(spacing: 6) {
            segment("我的 prompt", on: model.scope == .prompts) { model.scope = .prompts }
            segment("Agent 回复", on: model.scope == .replies) { model.scope = .replies }
            segment("全部", on: model.scope == .both) { model.scope = .both }

            Divider().frame(height: 16).overlay(Theme.stroke).padding(.horizontal, 4)

            segment("Claude", on: model.source == .claude, tint: Theme.claudeTint) {
                model.source = model.source == .claude ? nil : .claude
            }
            segment("Codex", on: model.source == .codex, tint: Theme.codexTint) {
                model.source = model.source == .codex ? nil : .codex
            }
            Spacer()
            if model.total > 0 {
                Text(String(format: "%d 条 · %.0f ms", model.total, model.elapsed))
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
        } else if model.groups.isEmpty {
            message(model.indexing ? model.indexNote : "", icon: "questionmark.circle",
                    tint: Theme.subtext)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.groups) { group in
                        groupCard(group)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
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

                Text(snippet(hit.body))
                    .font(.system(size: 11.5))
                    .foregroundColor(isPrompt ? Theme.text : Theme.subtext)
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
            Text(msg.body)
                .font(.system(size: 11.5, design: isPrompt ? .default : .monospaced))
                .foregroundColor(isHit ? Theme.text : Theme.subtext)
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

    /// One line, collapsed — a matched prompt is often a wall of pasted text.
    private func snippet(_ body: String) -> String {
        let flat = body.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
        return flat.count > 240 ? String(flat.prefix(240)) + "…" : flat
    }

    private func shortDate(_ iso: String) -> String {
        // "2026-07-29T10:23:30.123Z" → "07-29 10:23"
        guard iso.count >= 16 else { return "" }
        let d = iso.prefix(10).suffix(5)
        let t = iso.dropFirst(11).prefix(5)
        return "\(d) \(t)"
    }
}
