import AppKit
import SwiftUI
import WebKit

/// `FV_SNAPSHOT_FILES=<folder> FleetView --snapshot <dir>`: draw a file window on that folder to PNGs.
///
/// The board's snapshot mode, for the file window: the real views and the real editor page, in an
/// offscreen window, with no hooks, no web server and nothing written to `~/.fleetview` (the same
/// `CFFIXED_USER_HOME` guard applies). The editor is a web view, which `cacheDisplay` cannot see, so
/// its own snapshot is drawn into the picture where it sits.
///
/// `FV_SNAPSHOT_OPEN`: files to open, comma-separated, relative to the folder (the last is shown).
/// `FV_SNAPSHOT_EXPAND`: folders to open in the tree. `FV_SNAPSHOT_JS`: script run in the page after
/// the files are open — how a test types into the editor. `FV_SNAPSHOT_FILTER`, `FV_SNAPSHOT_SEARCH`,
/// `FV_SNAPSHOT_QUICK`: a name filter, a search in files, or quick open with that text.
/// `FV_SNAPSHOT_EDITED`: `path=Card,…`, writes an agent's hook would have reported.
/// `FV_SNAPSHOT_STEPS`: after all that, steps separated by `;;` — `js:<script>` in the page,
/// `sh:<command>` (an agent writing a file), `wait:<seconds>`, or `do:<overwrite|useDisk|save>` on the
/// tab in front, `do:card=<name>` (that card's commits) or `do:repo=<folder>` on the 提交 page — each
/// followed by a moment for the window to react. How a test drives a reload or
/// a conflict through the real model.
@MainActor
enum FileSnapshot {
    static func run(root: String, into dir: String) -> Never {
        let env = ProcessInfo.processInfo.environment
        let open = (env["FV_SNAPSHOT_OPEN"] ?? "").split(separator: ",").map(String.init)
        let expand = (env["FV_SNAPSHOT_EXPAND"] ?? "").split(separator: ",").map(String.init)
        let script = env["FV_SNAPSHOT_JS"]
        let state = AppState()
        let project = Project(name: (root as NSString).lastPathComponent, path: root, isGit: true)
        state.projects = [project]
        for (suffix, name) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: name)
            shoot(project, state: state, open: open, expand: expand, script: script, appearance: name,
                  to: "\(dir)/files-\(suffix).png")
        }
        exit(0)
    }

    private static func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private static func shoot(_ project: Project, state: AppState, open: [String], expand: [String], script: String?,
                              appearance: NSAppearance.Name, to path: String) {
        let env = ProcessInfo.processInfo.environment
        let size = NSSize(width: 1280, height: 800)
        let model = FileBrowserModel(project: project, app: state)
        let host = NSHostingView(rootView: FileBrowserView(model: model).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        model.window = window
        model.start()
        // `path=Card name,…`: what an agent's hook would have recorded, for the recently-changed list.
        for pair in (env["FV_SNAPSHOT_EDITED"] ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let t = TerminalSession(projectId: project.id, name: kv[1], cwd: project.path)
            FileEdits.shared.note([model.absolute(kv[0])], terminal: t)
        }
        spin(8) { model.editor.ready && !model.rows.isEmpty }
        for d in expand { model.toggle(d); spin(0.4) }
        for f in open { model.open(f, pin: true); spin(1.2) }
        if let q = env["FV_SNAPSHOT_FILTER"] { model.filter = q; spin(1.5) }
        if let q = env["FV_SNAPSHOT_SEARCH"] { model.sideMode = .search; model.searchQuery = q; model.runSearch(); spin(3) }
        if let q = env["FV_SNAPSHOT_QUICK"] { model.showQuickOpen(); model.quickQuery = q; spin(1.5) }
        if let script {
            var finished = false
            model.editor.webView.evaluateJavaScript(script) { _, _ in finished = true }
            spin(5) { finished }
        }
        for step in (env["FV_SNAPSHOT_STEPS"] ?? "").components(separatedBy: ";;") where !step.isEmpty {
            let (kind, arg) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
            switch kind {
            case "js":
                var finished = false
                model.editor.webView.evaluateJavaScript(arg) { r, _ in
                    if let r, !(r is NSNull) { print("files snapshot js → \(r)") }
                    finished = true
                }
                spin(5) { finished }
            case "sh":
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", arg]
                p.currentDirectoryURL = URL(fileURLWithPath: project.path)
                try? p.run()
                p.waitUntilExit()
            case "wait":
                spin(Double(arg) ?? 1)
            case "do":
                let id = model.activeTab ?? ""
                switch arg {
                case "overwrite": model.overwrite(id)
                case "restoreRecovered": model.restoreRecovered(id)
                case "history": model.sideMode = .history
                case "commit": if let c = model.commits.first { model.openCommit(c.sha) }
                case "uncommitted": model.openUncommitted()
                case let a where a.hasPrefix("fileHistory="): model.showHistory(of: String(a.dropFirst("fileHistory=".count)))
                case let a where a.hasPrefix("card="):
                    let name = String(a.dropFirst("card=".count))
                    if let c = model.committers.first(where: { $0.name == name }) ?? model.committers.first { model.showCommits(of: c) }
                case let a where a.hasPrefix("repo="): model.setHistoryRepo(String(a.dropFirst("repo=".count)))
                case "cardCommit": if let c = model.cardCommits.first { model.openCommit(c.commit.sha, in: c.repoFolder) }
                case "cardUncommitted": if let u = model.cardUncommitted.first { model.openUncommitted(u) }
                case "useDisk": model.useDiskVersion(id)
                case "save": model.saveTabs(model.unsavedTabs) { ok in print("files snapshot: saveTabs ok=\(ok)") }
                default: break
                }
            default: break
            }
            spin(1.5)
            print("files snapshot step \(kind): tabs=\(model.tabs.map { "\($0.path) dirty=\($0.dirty) ro=\($0.readOnly ?? "-")" }) banners=\(model.banners)")
        }
        spin(2.5)
        host.layoutSubtreeIfNeeded()

        // The page's own picture, laid over the web view as an ordinary image view, then the whole
        // window drawn: whatever SwiftUI puts above the editor (quick open, a toast) stays above it.
        let web = model.editor.webView
        var shot: NSImage?
        var done = false
        web.takeSnapshot(with: nil) { image, _ in shot = image; done = true }
        spin(5) { done }
        let cover = NSImageView(frame: web.bounds)
        cover.imageScaling = .scaleAxesIndependently
        cover.image = shot
        if shot != nil { web.addSubview(cover) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        cover.removeFromSuperview()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        // What the page reported, for a test to read: the tabs and their state.
        let tabs = model.tabs.map { "\($0.path) dirty=\($0.dirty) mode=\($0.mode.rawValue) ro=\($0.readOnly ?? "-")" }
        print("files snapshot \(path): rows=\(model.rows.count) marks=\(model.marks.count) repo=\(model.repo != nil) tabs=\(tabs) banners=\(model.banners) status=\(model.status) quick=\(model.quickResults.prefix(4).map(\.path)) recent=\(model.recent.map { "\($0.path):\($0.by ?? "-")" })")
        model.stop()
        window.contentView = nil
    }
}
