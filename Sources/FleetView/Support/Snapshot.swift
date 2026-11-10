import AppKit
import SwiftUI

/// `FleetView --snapshot <dir>`: draw the board with sample data to PNGs and exit.
///
/// The app cannot be launched to look at a UI change — a second instance steals the running one's
/// hook events (see CLAUDE.md) — and a redesign is nothing but UI changes. This draws the real views
/// in an offscreen window instead: no AppDelegate, no hooks, no web server, no tmux, nothing read
/// from or written to the user's state.
///
/// It refuses to run unless `CFFIXED_USER_HOME` points somewhere other than the real home, which is
/// what Foundation (and so `FV.home`) resolves the home directory from. Anything a view might touch
/// on disk then lands in that scratch home, never in `~/.fleetview`.
enum Snapshot {
    static var outputDir: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor static func run(into dir: String) -> Never {
        guard let fake = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              !fake.isEmpty, fake != NSHomeDirectoryForUser(NSUserName()) else {
            FileHandle.standardError.write(Data(
                "--snapshot needs CFFIXED_USER_HOME set to a scratch directory, so nothing touches ~/.fleetview\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let root = ProcessInfo.processInfo.environment["FV_SNAPSHOT_FILES"] { FileSnapshot.run(root: root, into: dir) }

        let state = AppState()
        let size = NSSize(width: 1512, height: 949)
        if SnapshotBench.requested {
            SnapshotBench.run(state, size: size, into: dir, sample: { fill($0) })
            exit(0)
        }
        fill(state)
        if ProcessInfo.processInfo.environment["FV_SNAPSHOT_ANIM"] != nil {
            recordSidebarFold(state, size: size, into: dir)
            exit(0)
        }
        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            state.dialog = nil
            shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                  to: "\(dir)/board-\(suffix).png")
            state.sidebarHidden = true
            shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                  to: "\(dir)/board-nosidebar-\(suffix).png")
            state.sidebarHidden = false
            // The whole board, scrolled or not: what sits below the first screen matters too.
            shoot(DashboardView().environmentObject(state), size: NSSize(width: size.width, height: 2000),
                  appearance: appearance, to: "\(dir)/board-tall-\(suffix).png")
            state.dialog = .webLink(terminalId: state.terminals.first { $0.status == .working }?.id)
            shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                  to: "\(dir)/dialog-web-\(suffix).png")
            state.dialog = .closeAll
            shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                  to: "\(dir)/dialog-close-\(suffix).png")
            state.dialog = .shareSettings
            shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                  to: "\(dir)/dialog-share-\(suffix).png")
            state.dialog = .theme
            shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                  to: "\(dir)/dialog-theme-\(suffix).png")
            // The board in every preset seed, and one far from all of them (a yellow, where the
            // harmonised amber and the primary come closest).
            if ProcessInfo.processInfo.environment["FV_SNAPSHOT_SEEDS"] != nil {
                let keptSeed = ThemeStore.shared.seed
                for (name, seed) in MaterialScheme.presets + [("yellow", 0xC9A400)] {
                    ThemeStore.shared.setSeed(seed, persist: false)
                    shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                          to: "\(dir)/seed-\(name)-\(suffix).png")
                }
                ThemeStore.shared.setSeed(keptSeed, persist: false)
            }
            state.dialog = nil
            shoot(FleetTriggersPopover().environmentObject(state), size: NSSize(width: 500, height: 640),
                  appearance: appearance, to: "\(dir)/fleet-triggers-\(suffix).png")
            let keptArchive = state.terminalArchive
            fillRecentProjects(state)
            shoot(RecentProjectsPopover(close: {}).environmentObject(state), size: NSSize(width: 420, height: 640),
                  appearance: appearance, to: "\(dir)/recent-projects-\(suffix).png")
            state.terminalArchive = keptArchive
            // Mid-drag: deploy lifted over the grid-skeleton card's neighbourhood, the dock up.
            if let dragged = state.terminals.first(where: { $0.name == "deploy" }),
               let target = state.terminals.first(where: { $0.name == "grid-skeleton" }) {
                state.dialog = nil
                state.draggingTerminalId = dragged.id
                state.dragLocation = CGPoint(x: 900, y: 560)
                state.clusterDrop = .project(target.projectId)
                shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                      to: "\(dir)/drag-\(suffix).png")
                state.draggingTerminalId = nil
                state.clusterDrop = nil
            }
            // The session tree, when a real transcript is named (read only): FV_SNAPSHOT_TRANSCRIPT.
            if let path = ProcessInfo.processInfo.environment["FV_SNAPSHOT_TRANSCRIPT"],
               let i = state.terminals.firstIndex(where: { $0.name == treeTerminal }) {
                state.dialog = nil
                state.terminals[i].transcriptPath = path
                state.openSessionTree(state.terminals[i].id)
                let deadline = Date().addingTimeInterval(15)
                while (state.treeModel.loading || state.treeModel.rows.isEmpty), Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                }
                shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                      to: "\(dir)/tree-\(suffix).png")
                // A pinned turn: the one before the current leaf, so there are rows on both sides of
                // it; the root when the path is a single turn.
                let tree = state.treeModel.tree
                let leaf = tree.activeLeafNode ?? state.treeModel.rows.compactMap(\.nodeUuid).first
                if let leaf, case let u = tree.nodes[leaf]?.parent ?? leaf,
                   !(tree.nodes[u]?.answer.isEmpty ?? true) {
                    state.treeModel.selected = u
                    state.treeModel.focus.focusY = 420
                    shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                          to: "\(dir)/tree-pinned-\(suffix).png")
                    state.treeModel.selected = nil
                }
                state.closeSessionTree()
            }
            state.dialog = nil
            state.searchModel.app = state
            state.searchOpen = true
            state.searchModel.query = "FleetView"
            shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                  to: "\(dir)/search-\(suffix).png")
            state.searchOpen = false
            state.searchModel.reset()
            // The trigger panel, for the card the sample gives a schedule to. Set directly rather
            // than through `openTriggers`, whose look at the scratch home's LaunchAgents would
            // replace the sample's launchd job with nothing.
            if let rt = state.terminals.first(where: { $0.name == treeTerminal }) {
                state.triggersPanelTerminalId = rt.id
                shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                      to: "\(dir)/triggers-\(suffix).png")
                state.triggersPanelTerminalId = nil
            }
            // Conversation search over whatever the scratch home's agent folders hold:
            // FV_SNAPSHOT_HISTORY=<query>. Drawn folded, then with the first project open.
            if let q = ProcessInfo.processInfo.environment["FV_SNAPSHOT_HISTORY"] {
                let m = state.searchModel
                m.app = state
                state.searchOpen = true
                m.mode = .history
                m.refreshIndex()
                m.query = q
                let deadline = Date().addingTimeInterval(20)
                while (m.indexing || m.projectGroups.isEmpty), Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // the debounced search
                shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                      to: "\(dir)/search-history-\(suffix).png")
                if let first = m.projectGroups.first {
                    m.toggle(first)
                    if let hit = first.sessions.flatMap(\.hits).max(by: { $0.ts < $1.ts }) {
                        m.selectedKey = "h:\(hit.id)"
                        m.showPreview(hit)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    }
                    shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                          to: "\(dir)/search-history-open-\(suffix).png")
                }
                // The card level: a project's two busiest conversations handed to two cards on the
                // board and searched again, the busier card opened — then that card asked for by name.
                let busiest = (m.projectGroups.first { $0.sessions.count > 1 }?.sessions ?? [])
                    .sorted { $0.hits.count > $1.hits.count }
                if busiest.count > 1, busiest[0].hits.count > 1, state.terminals.count > 1 {
                    let saved = state.terminals.map(\.transcriptPath)
                    state.terminals[0].transcriptPath = busiest[0].id
                    state.terminals[1].transcriptPath = busiest[1].id
                    func settle(_ done: () -> Bool) {
                        let deadline = Date().addingTimeInterval(10)
                        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
                        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    }
                    m.reset()                         // the cards are read once per opening
                    state.searchOpen = true
                    m.mode = .history
                    m.query = q
                    settle { m.groups.contains { $0.holder != nil } }
                    if let p = m.projectGroups.first(where: { !$0.cards.isEmpty }), let c = p.cards.first {
                        // Folded first, as it arrives, with the card selected...
                        m.expandedProjects.insert(p.id)
                        m.expandedCards = []
                        m.selectedKey = "c:\(c.id)"
                        settle { true }
                        shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                              to: "\(dir)/search-history-cards-folded-\(suffix).png")
                        // ...then opened, on its newest message.
                        m.expandedCards = [c.id]
                        if let hit = c.sessions.flatMap(\.hits).max(by: { $0.ts < $1.ts }) {
                            m.selectedKey = "h:\(hit.id)"
                            m.showPreview(hit)
                            settle { m.preview?.id == hit.id }
                        }
                        shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                              to: "\(dir)/search-history-cards-\(suffix).png")
                    }
                    m.query = state.terminals[0].name
                    settle { m.groups.contains { $0.byCardName } }
                    shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                          to: "\(dir)/search-history-byname-\(suffix).png")
                    for (i, p) in saved.enumerated() { state.terminals[i].transcriptPath = p }
                    m.query = q
                    settle { !m.projectGroups.isEmpty }
                }
                let found = m.groups
                state.searchOpen = false
                m.reset()
                // The same conversations as removed cards of the first project, opened the way its
                // archive button opens them, with the newest card selected.
                if let home = state.projects.first {
                    let names = ["tray-layout", "search panel", "deploy 212", "perf pass", "web fold"]
                    state.terminalArchive = zip(found, names).enumerated().map { i, pair in
                        TerminalArchive(id: UUID(), projectId: home.id, projectPath: home.path,
                                        name: pair.1, cwd: home.path, sessionId: nil,
                                        transcriptPath: pair.0.id,
                                        lastPrompt: pair.0.hits.first { $0.role == .user }?.body ?? "",
                                        removedAt: Date().addingTimeInterval(Double(-3600 * i)))
                    }
                    state.openArchive(projectId: home.id)
                    let deadline = Date().addingTimeInterval(10)
                    while m.projectGroups.isEmpty, Date() < deadline {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    }
                    if let hit = m.projectGroups.flatMap(\.sessions).flatMap(\.hits).max(by: { $0.ts < $1.ts }) {
                        m.selectedKey = "h:\(hit.id)"
                        m.showPreview(hit)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    }
                    shoot(DashboardView().environmentObject(state), size: size, appearance: appearance,
                          to: "\(dir)/search-archive-\(suffix).png")
                    state.closeSearch()
                    state.terminalArchive = []
                }
            }
        }
        exit(0)
    }

    /// Re-dates the sample's fresh changes before every shot: they are fresh for ten seconds, and a
    /// full run of shots takes longer than that.
    @MainActor private static var freshen: () -> Void = {}

    @MainActor private static func shoot<V: View>(_ view: V, size: NSSize,
                                                  appearance: NSAppearance.Name, to path: String) {
        freshen()
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        // Let SwiftUI lay out and settle (preferences, GeometryReaders) before drawing.
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }

    /// `FV_SNAPSHOT_ANIM=1`: frames of the board while the sidebar folds, as anim-NN.png.
    ///
    /// How the cards' jump on a fold was found and its fix checked: the still shots cannot show
    /// motion. The window is really drawn (ordered in, far off screen), since an animation does not
    /// run in one that is never shown. Only a band through the sample board's FleetView section is
    /// grabbed — where a fold moves a card from the second row up into the first — and the frames
    /// are kept in memory until the end, because a whole-window grab and a PNG per frame each took
    /// longer than the fold. Even so a frame takes ~0.1 s, which is about two frames of a 0.22 s
    /// animation: lengthen the fold and `BoardGrid.reflow` in the source while looking.
    @MainActor private static func recordSidebarFold(_ state: AppState, size: NSSize, into dir: String) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: DashboardView().environmentObject(state))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        freshen()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let region = NSRect(x: 0, y: 500, width: size.width, height: 330)
        var frames: [(Double, NSBitmapImageRep)] = []
        let t0 = Date()
        func grab() {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: region) else { return }
            host.cacheDisplay(in: region, to: rep)
            frames.append((Date().timeIntervalSince(t0) * 1000, rep))
        }
        grab()
        state.toggleSidebar()
        while Date().timeIntervalSince(t0) < 3.2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            grab()
        }
        window.orderOut(nil)
        for (i, (ms, rep)) in frames.enumerated() {
            FileHandle.standardError.write(Data(String(format: "frame %02d at %.0f ms\n", i, ms).utf8))
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: String(format: "%@/anim-%02d.png", dir, i)))
        }
    }

    /// The terminal the session tree is drawn for when `FV_SNAPSHOT_TRANSCRIPT` names a transcript.
    private static let treeTerminal = "ride-tracker"

    /// A board with one of everything: needs-you, running, idle, shell, exited, closed, a cluster,
    /// a marked card, dormant projects, notes.
    ///
    /// Also what the README's screenshots are drawn from, so it is invented, worded in the language
    /// the UI is drawn in, and names nothing on this machine: run it with `-AppleLanguages "(en)"`
    /// or `"(zh-Hans)"` for each README.
    /// Fleet triggers in each state a row can be in: running, failed, paused, once and done, from
    /// a card on the board, from a removed one, and from no card.
    @MainActor private static func fillFleetTriggers(_ s: AppState) {
        let now = Date()
        let card = s.terminals.first?.id.uuidString
        func t(_ id: String, _ name: String, _ when: FleetTriggerWhen, _ run: String, source: String?,
               due: Date? = nil, last: FleetTriggerRun? = nil, paused: Bool? = nil) -> FleetTrigger {
            FleetTrigger(id: id, name: name, when: when, run: run, cwd: nil, timeout: nil, source: source,
                         sourceName: "nightly-review", sourceTranscript: nil, createdAt: now, paused: paused,
                         due: due, last: last, runs: last == nil ? 0 : 3)
        }
        s.fleetTriggers = [
            FleetTriggerStatus(trigger: t("3f9a1c2e", "daily review", FleetTriggerWhen(kind: "cron", cron: "0 9 * * *"),
                "project-manager subagent -p FleetView --rm 'Review yesterday’s commits and list anything risky'",
                source: card, due: Calendar.current.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0), matchingPolicy: .nextTime),
                last: FleetTriggerRun(at: now.addingTimeInterval(-15 * 3600), reason: "cron", exit: 0, seconds: 214,
                                      tail: "done  8e43b236  ⚙ daily review · ran 3m\nreply:\nNo risky changes.")),
                running: false),
            FleetTriggerStatus(trigger: t("a07be511", "watch inbox", FleetTriggerWhen(kind: "watch", path: FV.home.appendingPathComponent("inbox").path),
                "project-manager subagent --resume 34538a3e --rm 'New files in ~/inbox: sort them'",
                source: UUID().uuidString,
                last: FleetTriggerRun(at: now.addingTimeInterval(-60), reason: "watch")), running: true),
            FleetTriggerStatus(trigger: t("c4410d9b", "deploy when green", FleetTriggerWhen(kind: "check", check: "gh run list -L1 --json conclusion | grep -q success", interval: 120),
                "./scripts/package_app.sh --install", source: card,
                last: FleetTriggerRun(at: now.addingTimeInterval(-7200), reason: "check", exit: 0, seconds: 41, tail: "installed FleetView.app")),
                running: false),
        ]
    }

    /// Projects that have left the board, for the recent-projects menu: real folders in the scratch
    /// home, since the menu only lists one that still exists, and removed cards to count.
    @MainActor private static func fillRecentProjects(_ s: AppState) {
        let now = Date()
        let root = FV.home.appendingPathComponent("PycharmProjects")
        var archive: [TerminalArchive] = []
        s.recentProjects = []
        for (name, ago, cards) in [("invoice-ocr", 5_400.0, 6), ("treeflow", 86_400.0 * 2, 14),
                                   ("blog", 86_400.0 * 9, 0), ("ale-visual-port", 86_400.0 * 31, 41)] {
            let dir = root.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            s.recentProjects.append(RecentProject(path: dir.path, name: name, lastUsed: now.addingTimeInterval(-ago)))
            for i in 0..<cards {
                archive.append(TerminalArchive(id: UUID(), projectId: UUID(), projectPath: dir.path,
                                               name: "\(name)-\(i + 1)", cwd: dir.path, agentKind: .claude,
                                               transcriptPath: "/tmp/\(name)-\(i).jsonl",
                                               removedAt: now.addingTimeInterval(-ago - Double(i) * 600)))
            }
        }
        if let fv = s.projects.first {
            for i in 0..<3 {
                archive.append(TerminalArchive(id: UUID(), projectId: fv.id, projectPath: fv.path,
                                               name: "old-\(i)", cwd: fv.path, agentKind: .codex,
                                               transcriptPath: "/tmp/fv-\(i).jsonl",
                                               removedAt: now.addingTimeInterval(-86_400)))
            }
        }
        s.terminalArchive = archive
    }

    @MainActor private static func fill(_ s: AppState) {
        defer { fillFleetTriggers(s) }
        let now = Date()
        func w(_ en: String, _ zh: String) -> String { Lang.current == .zh ? zh : en }
        let fv = Project(name: "FleetView", path: "/Users/me/dev/FleetView", isGit: true)
        let shop = Project(name: "web-store", path: "/Users/me/dev/web-store", isGit: true)
        let data = Project(name: "data-pipeline", path: "/Users/me/dev/data-pipeline", isGit: true)
        let rides = Project(name: "ride-tracker", path: "/Users/me/dev/ride-tracker", isGit: true)
        let tmp = Project(name: "scratch", path: "/Users/me/scratch", isGit: false)
        s.projects = [fv, shop, data, rides, tmp]

        func t(_ p: Project, _ name: String, _ status: TermStatus, _ agent: AgentKind, ago: Double,
               prompt: String, tokens: Int = 0, running: Double? = nil) -> TerminalSession {
            var x = TerminalSession(projectId: p.id, name: name, cwd: p.path)
            x.status = status
            x.agentKind = agent
            x.lastPrompt = prompt
            x.newTokens = tokens
            x.lastActivity = now.addingTimeInterval(-ago)
            if let running { x.runningSince = now.addingTimeInterval(-running) }
            return x
        }
        var fv1 = t(fv, "deploy", .idle, .claude, ago: 1500, prompt: w("Deploy and push", "部署并 push"),
                    tokens: 412_000)
        fv1.subtaskDone = true
        let cluster = Cluster(name: "backfill")
        var d1 = t(data, "backfill-a", .idle, .claude, ago: 345_600,
                   prompt: w("Backfill September's events into the warehouse, one partition per day",
                             "把九月的事件回填到数仓，按天分区"), tokens: 9_300_000)
        d1.clusterId = cluster.id
        var d2 = t(data, "backfill-b", .idle, .codex, ago: 432_000,
                   prompt: w("Same task, another way: re-run only the days that failed",
                             "同一个任务换个做法：只重跑失败的那几天"), tokens: 3_700_000)
        d2.clusterId = cluster.id
        s.clusters = [cluster]
        s.wokenProjects = [data.id]       // so the group's outline is in the tall shot
        s.terminals = [
            t(fv, "release-build", .needsYou, .codex, ago: 60,
              prompt: w("Allow swift build? It needs to write to .build/", "允许运行 swift build？需要写入 .build/ 目录"),
              tokens: 230_000),
            t(fv, "color-audit", .working, .claude, ago: 5,
              prompt: w("Rework the colours and labels so a card's state reads from its shape and colour alone",
                        "重新设计配色和标签，让卡片的状态只看形状和颜色就能分辨"),
              tokens: 64_000, running: 132),
            fv1,
            t(fv, "web-check", .exited, .claude, ago: 7200,
              prompt: w("Make the web panel reconnect with exponential backoff", "把 Web 面板的断线重连改成指数退避"),
              tokens: 38_000),
            t(fv, "release-notes", .closed, .claude, ago: 259_200,
              prompt: w("Draft the 0.9 release notes", "整理 0.9 版本的更新说明"), tokens: 12_000),
            t(shop, "checkout-e2e", .working, .codex, ago: 2,
              prompt: w("Run the checkout e2e suite and group the failures by module in report.md",
                        "跑完结账流程的端到端测试，把失败用例按模块归类，写到 report.md"),
              tokens: 1_200_000, running: 847),
            t(shop, "grid-skeleton", .working, .claude, ago: 1,
              prompt: w("Add a loading skeleton to the product grid", "给商品网格加一个加载骨架屏"),
              tokens: 3_100_000, running: 2),
            t(shop, "dev-server", .shell, .unknown, ago: 3600, prompt: "npm run dev"),
            d1, d2,
            t(rides, treeTerminal, .idle, .claude, ago: 518_400,
              prompt: w("The GPS tracks from my last two rides keep drifting — take a look",
                        "最近两次骑行的 GPS 轨迹总是漂，帮我看看"),
              tokens: 3_900_000),
            t(tmp, "probe", .shell, .unknown, ago: 18_000,
              prompt: "curl -s localhost:8080/state | jq '.terminals | length'"),
            t(tmp, "load-test", .closed, .unknown, ago: 18_000,
              prompt: "for i in $(seq 50); do curl -s localhost:8123/health; done"),
        ]
        // One run that has just started (grid-skeleton) and one that has just finished (deploy),
        // so both fresh colours are in every shot.
        freshen = { [weak s] in
            guard let s else { return }
            if let i = s.terminals.firstIndex(where: { $0.name == "grid-skeleton" }) {
                s.terminals[i].runningSince = Date().addingTimeInterval(-2)
            }
            if let fv1 = s.terminals.first(where: { $0.name == "deploy" }) {
                s.runEndedAt[fv1.id] = Date().addingTimeInterval(-2)
            }
            // Commits two cards have made, so the git chip is in every shot.
            for (name, n) in [("deploy", 7), ("color-audit", 2)] {
                if let t = s.terminals.first(where: { $0.name == name }) { s.cardCommitCounts[t.id] = n }
            }
            // …one with uncommitted work besides, and one with only that.
            for (name, n) in [("color-audit", 3), ("grid-skeleton", 4)] {
                if let t = s.terminals.first(where: { $0.name == name }) { s.cardUncommittedCounts[t.id] = n }
            }
        }
        // Things that will make an agent act on its own (see AgentTrigger): a recurring check and
        // a /loop-style one-shot on ride-tracker, background work on backfill-a, and a LaunchAgent
        // that pings ride-tracker hourly — one of each kind the panel lists.
        // A one-shot forty minutes out, written the way Claude pins one: minute, hour, day, month.
        let at = Calendar.current.dateComponents([.minute, .hour, .day, .month], from: now.addingTimeInterval(2400))
        let soon = "\(at.minute!) \(at.hour!) \(at.day!) \(at.month!) *"
        if let rt = s.terminals.first(where: { $0.name == treeTerminal }) {
            s.triggerReports[rt.id] = TriggerReport(at: now.addingTimeInterval(-240), items: [
                AgentTrigger(kind: .cron, id: "fa91d4ca", schedule: "9,29,49 * * * *", recurring: true,
                             text: w("[Ride check — every 20 min] Re-run the drift analysis on any new GPX files in ~/rides and post a one-line summary.",
                                     "[骑行检查 · 每 20 分钟] 对 ~/rides 里新增的 GPX 文件重跑一次漂移分析，用一句话汇报结果。")),
                AgentTrigger(kind: .cron, id: "65eaac32", schedule: soon, recurring: false,
                             text: w("Check whether the map-matching job has finished; if so, compare the two tracks.",
                                     "看看地图匹配任务跑完没有；跑完了就对比两条轨迹。")),
            ])
            s.launchdTriggers[rt.id] = [
                AgentTrigger(kind: .launchd, id: "com.example.progress-ping.ride", schedule: "24 * * * *",
                             recurring: true, text: w("progress-ping.sh How is it going?", "progress-ping.sh 进度如何？"),
                             command: "/bin/bash ~/scripts/progress-ping.sh", path: "/tmp/none.plist"),
            ]
        }
        if let b = s.terminals.first(where: { $0.name == "backfill-a" }) {
            s.triggerReports[b.id] = TriggerReport(at: now.addingTimeInterval(-3600), items: [
                AgentTrigger(kind: .background, id: "b6nqyz1wh", schedule: nil, recurring: nil,
                             text: w("Wait for the warehouse load to finish", "等数仓导入跑完"),
                             taskType: "shell", status: "running",
                             command: "until grep -q LOADED load.log; do sleep 60; done"),
            ])
        }
        s.notes = [Note(text: "claude --dangerously-skip-permissions"),
                   Note(text: "claude --resume"),
                   Note(text: "~/dev/FleetView/docs/design"),
                   Note(text: "ssh mini.local 'tmux -L fleetview ls'")]
        s.showRecentStrip = true
    }
}
