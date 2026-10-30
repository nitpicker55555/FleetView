import AppKit
import FleetViewFiles
import SwiftUI

/// The sidebar's 提交 page: a repository's commits, newest first.
struct HistoryPane: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.repos.isEmpty && model.externalRepos.isEmpty && model.historyCard == nil {
                Text(L(.histNotARepo)).font(.fvBodySmall).foregroundColor(Theme.subtext)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                Spacer()
            } else {
                header
                chips
                Divider().overlay(Theme.outlineVariant)
                list
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 4) {
            if model.historyCard == nil && model.repos.count + model.externalRepos.count > 1 {
                Menu {
                    ForEach(model.repos, id: \.folder) { r in
                        Button(Self.repoName(r, model)) { model.setHistoryRepo(r.folder) }
                    }
                    if !model.externalRepos.isEmpty {
                        Section(L(.histOtherRepos)) {
                            ForEach(model.externalRepos, id: \.folder) { r in
                                Button(Self.repoName(r, model)) { model.setHistoryRepo(r.folder) }
                                    .help(r.folder)
                            }
                        }
                    }
                } label: {
                    Text(model.repo(folder: model.historyRepo).map { Self.repoName($0, model) } ?? "")
                }
                .menuStyle(.borderlessButton).fixedSize().font(.fvLabel)
            }
            if model.historyCard == nil { branchMenu }
            if !model.committers.isEmpty || model.historyCard != nil { cardMenu }
            Spacer(minLength: 4)
            Button {
                if let c = model.historyCard { model.showCommits(of: c) } else { model.loadHistory(); model.loadBranches() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.borderless).help(L(.histReload))
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    /// The cards of this project that have committed: picking one lists its commits, in whatever
    /// repository they went to.
    private var cardMenu: some View {
        Menu {
            Button(L(.histAllCommits)) { model.clearCardFilter() }
            Divider()
            ForEach(model.committers, id: \.id) { a in
                Button((model.historyCard?.id == a.id ? "● " : "") + model.authorName(a)) { model.showCommits(of: a) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "person.crop.square").font(.system(size: 11))
                if let c = model.historyCard { Text(c.name).lineLimit(1) }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().font(.fvLabel)
        .help(L(.histByCardHelp))
    }

    private var branchMenu: some View {
            Menu {
                Button(L(.histCurrentBranch(model.historyCurrentBranch ?? "HEAD"))) { model.setHistoryRef(nil) }
                let local = model.branchList.filter { !$0.isRemote }
                let remote = model.branchList.filter(\.isRemote)
                if !local.isEmpty {
                    Divider()
                    ForEach(local, id: \.name) { b in
                        Button((b.isHead ? "● " : "") + b.name) { model.setHistoryRef(b.isHead ? nil : b.name) }
                    }
                }
                if !remote.isEmpty {
                    Menu(L(.histRemoteBranches)) {
                        ForEach(remote, id: \.name) { b in Button(b.name) { model.setHistoryRef(b.name) } }
                    }
                }
                if let ref = model.historyRef, ref != model.historyCurrentBranch {
                    Divider()
                    Button(L(.histCompareWithCurrent(ref))) { model.compareBranch(ref) }
                }
            } label: {
                Text("⎇ " + (model.historyRef ?? model.historyCurrentBranch ?? "HEAD")).font(.fvMono)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L(.histBranchHelp))
    }

    static func repoName(_ r: RepoRef, _ model: FileBrowserModel) -> String { model.repoName(r) }

    @ViewBuilder private var chips: some View {
        if let c = model.historyCard {
            chip(L(.histCardOnly(model.authorName(c))), help: L(.histByCardHelp)) { model.clearCardFilter() }
        }
        if model.historyCard == nil, let p = model.historyPath {
            chip(L(.histOnly((p as NSString).lastPathComponent)), help: p) { model.clearHistoryPath() }
        }
        if let pick = model.comparePick {
            chip(L(.histPicked(String(pick.prefix(7)))), help: L(.histPickedHelp)) { model.comparePick = nil }
        }
    }

    private func chip(_ text: String, help: String, close: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.fvLabelSmall).lineLimit(1)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain)
        }
        .foregroundColor(Theme.onSecondaryContainer)
        .padding(.horizontal, 8).frame(height: 20)
        .background(Theme.secondaryContainer).clipShape(Capsule())
        .padding(.horizontal, 10).padding(.bottom, 6)
        .help(help)
    }

    // MARK: list

    private var activeSha: String? { model.active?.changes?.sha }

    private var list: some View {
        ScrollView {
            if model.historyCard != nil { cardList } else { repoList }
        }
    }

    /// One card's commits, newest first, each saying which repository it went to when that is not
    /// the one the window belongs to.
    private var cardList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            // What the card wrote and nobody has committed, above what it committed — the same place
            // the working tree's row has in a repository's list.
            ForEach(model.cardUncommitted) { u in
                let on = model.active?.changes.map { $0.only == u.files && $0.repoFolder == u.repoFolder } ?? false
                HStack(spacing: 6) {
                    Circle().fill(Theme.warn).frame(width: 7, height: 7)
                    Text(L(.histUncommitted(u.files.count))).font(.system(size: 12.5)).foregroundColor(Theme.text)
                    if !u.repoFolder.isEmpty, let r = model.repo(folder: u.repoFolder) {
                        Text(model.repoName(r)).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            .foregroundColor(Theme.onTertiaryContainer)
                            .padding(.horizontal, 5).frame(height: 15)
                            .background(Theme.tertiaryContainer).clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).frame(height: 30)
                .background(on ? Theme.secondaryContainer : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { model.openUncommitted(u) }
                .help(model.repo(folder: u.repoFolder).map(\.repo.toplevel) ?? "")
            }
            ForEach(model.cardCommits) { cc in
                let r = model.repo(folder: cc.repoFolder)
                CommitRow(commit: cc.commit, selected: activeSha == cc.commit.sha, picked: false,
                          repo: cc.repoFolder.isEmpty ? nil : r.map { model.repoName($0) })
                    .contentShape(Rectangle())
                    .gesture(TapGesture(count: 1).onEnded { model.openCommit(cc.commit.sha, in: cc.repoFolder) })
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.openCommit(cc.commit.sha, in: cc.repoFolder, pin: true) })
                    .help((r?.repo.toplevel ?? cc.repoFolder) + "\n" + cc.commit.sha + "\n" + cc.commit.subject)
            }
            if model.cardCommitsLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L(.filesSearching)).font(.fvLabelSmall).foregroundColor(Theme.outline)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            } else if model.cardCommits.isEmpty && model.cardUncommitted.isEmpty {
                Text(L(.histCardNone)).font(.fvBodySmall).foregroundColor(Theme.outline)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .padding(.vertical, 4)
    }

    private var repoList: some View {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.historyRef == nil, model.historyUncommitted > 0 {
                    let on = model.active?.changes.map { if case .worktree("HEAD") = $0.range { return true }; return false } ?? false
                    HStack(spacing: 6) {
                        Circle().fill(Theme.warn).frame(width: 7, height: 7)
                        Text(L(.histUncommitted(model.historyUncommitted))).font(.system(size: 12.5)).foregroundColor(Theme.text)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(on ? Theme.secondaryContainer : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { model.openUncommitted() }
                }
                ForEach(model.commits, id: \.sha) { c in
                    let author = model.commitAuthors[c.sha]
                    CommitRow(commit: c, selected: activeSha == c.sha, picked: model.comparePick == c.sha,
                              card: author?.name, cardRemoved: author?.removed == true,
                              onCard: author.map { a in { model.showCommits(of: a) } })
                        .contentShape(Rectangle())
                        .gesture(TapGesture(count: 1).onEnded { model.openCommit(c.sha) })
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openCommit(c.sha, pin: true) })
                        .contextMenu { menu(c) }
                }
                footer
            }
            .padding(.vertical, 4)
    }

    @ViewBuilder private func menu(_ c: GitCommit) -> some View {
        Button(L(.histOpenCommit)) { model.openCommit(c.sha, pin: true) }
        Button(L(.histCompareWorktree)) { model.compareWithWorktree(c.sha) }
        if let pick = model.comparePick, pick != c.sha {
            Button(L(.histCompareWithPicked(String(pick.prefix(7))))) { model.compare(pick, c.sha) }
        } else {
            Button(L(.histPickForCompare)) { model.comparePick = c.sha }
        }
        Divider()
        Button(L(.histCopySha)) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(c.sha, forType: .string)
            model.showToast(L(.filesCopied))
        }
        Button(L(.histCopySubject)) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(c.subject, forType: .string)
            model.showToast(L(.filesCopied))
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.historyState {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L(.filesSearching)).font(.fvLabelSmall).foregroundColor(Theme.outline)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        case .loaded(let more):
            if model.commits.isEmpty {
                Text(L(.histNone)).font(.fvBodySmall).foregroundColor(Theme.outline).padding(.horizontal, 12).padding(.vertical, 8)
            } else if more {
                Button { model.loadHistory(more: true) } label: {
                    Text(L(.histMore)).font(.fvLabel).foregroundColor(Theme.primary)
                }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 8)
            }
        case .failed:
            Text(L(.histNone)).font(.fvBodySmall).foregroundColor(Theme.outline).padding(.horizontal, 12).padding(.vertical, 8)
        case .idle:
            EmptyView()
        }
    }
}

/// One commit in the list: its subject, then sha, refs, author, age, agent and counts.
struct CommitRow: View {
    let commit: GitCommit
    let selected: Bool
    let picked: Bool
    /// The card that made it, when its conversation says so; tapping it lists that card's commits.
    var card: String? = nil
    /// The card is no longer on the board: drawn faded rather than labelled, which the row has no room for.
    var cardRemoved = false
    var onCard: (() -> Void)? = nil
    /// The repository it is in, in a card's list, where commits from several are side by side.
    var repo: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The subject gives way to the refs, the author to the sha and the counts: what tells
            // commits apart stays whole.
            HStack(spacing: 5) {
                Text(commit.subject).font(.system(size: 12.5)).foregroundColor(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                // One ref, shortened if need be, and how many more: a commit with three tags must
                // still show what it is.
                let refs = Self.refs(commit.refs)
                if let first = refs.first {
                    let name = first.count > 16 ? first.prefix(14) + "…" : Substring(first)
                    Text(refs.count > 1 ? "\(name) +\(refs.count - 1)" : String(name))
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .foregroundColor(Theme.onTertiaryContainer)
                        .padding(.horizontal, 5).frame(height: 15)
                        .background(Theme.tertiaryContainer).clipShape(Capsule())
                        .fixedSize()
                        .help(refs.joined(separator: ", "))
                }
            }
            HStack(spacing: 5) {
                Text(commit.short).font(.fvMono).foregroundColor(Theme.primary).fixedSize()
                // The card stands in for the author: on this machine the author is the same person on
                // every commit, and which card made it is what tells them apart.
                TimelineView(.periodic(from: commit.date, by: 60)) { ctx in
                    Text(RelativeTime.compact(commit.date, now: ctx.date) + (card == nil ? " · " + commit.author : ""))
                        .lineLimit(1)
                }
                .foregroundColor(Theme.outline)
                .layoutPriority(1)
                if let card {
                    Text(card).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        .foregroundColor(Theme.onSecondaryContainer)
                        .padding(.horizontal, 5).frame(height: 15)
                        .background(Theme.secondaryContainer).clipShape(Capsule())
                        .opacity(cardRemoved ? 0.55 : 1)
                        .layoutPriority(2)
                        .onTapGesture { onCard?() }
                        .help(L(.histCardCredit(cardRemoved ? L(.histCardRemoved(card)) : card)))
                }
                if let repo {
                    Text(repo).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .foregroundColor(Theme.onTertiaryContainer)
                        .padding(.horizontal, 5).frame(height: 15)
                        .background(Theme.tertiaryContainer).clipShape(Capsule())
                }
                Spacer(minLength: 4)
                // Which agent is already said by the card, when there is one.
                if card == nil, let agent = commit.agent {
                    Text(agent == "claude" ? "Claude" : "Codex").font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.onPrimaryContainer)
                        .padding(.horizontal, 5).frame(height: 15)
                        .background(Theme.primaryContainer).clipShape(Capsule())
                        .fixedSize()
                }
                if let a = commit.added, let d = commit.deleted {
                    HStack(spacing: 3) {
                        Text("+\(a)").foregroundColor(Theme.primary)
                        Text("−\(d)").foregroundColor(Theme.error)
                    }
                    .fixedSize()
                }
            }
            .font(.fvLabelSmall)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(selected ? Theme.secondaryContainer : (picked ? Theme.surfaceContainerHigh : Color.clear))
        .help(commit.sha + "\n" + commit.subject)
    }

    /// `HEAD -> main` → `main`, `tag: v1` → `v1`; HEAD alone (detached) stays.
    static func refs(_ list: [String]) -> [String] {
        list.map { r in
            if r.hasPrefix("HEAD -> ") { return String(r.dropFirst(8)) }
            if r.hasPrefix("tag: ") { return String(r.dropFirst(5)) }
            return r
        }
    }
}
