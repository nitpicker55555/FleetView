import CoreGraphics
import Foundation

/// Everything FleetView starts that is not a window: shared by the desktop app and a headless run,
/// so the two serve the same board, the same API and the same hooks, started in the same order.
@MainActor
enum AppStartup {
    static func start(_ state: AppState) -> EventWatcher {
        state.load()
        // Start auditing right after load, before anything can mutate state: the first snapshot is
        // the baseline every later diff is measured against.
        AppAudit.shared.start(state)

        // Live status via Claude Code hooks (reversible; no-ops for terminals FleetView didn't launch).
        HookInstaller.install()
        CodexHookInstaller.install() // same pipeline for Codex CLI (only if ~/.codex already exists)
        ShellIntegration.install()   // zsh command capture for FleetView-launched terminals
        RemoteServer.installConfig() // tmux config for LAN web access (harmless if tmux is absent)
        state.web.app = state
        state.web.start()            // web dashboard (mirror of this window) on the LAN
        state.startPanelWatch()      // hot-load the agent-authored top panel (no relaunch needed)
        // Warm the conversation-search index in the background. The first build reads every
        // transcript on disk (~15 s); every refresh after that is incremental and near-free, so
        // doing it at launch means ⌘K is instant instead of waiting on a cold index.
        SearchIndex.refresh()
        // …and keep it warm. `project-manager projects/history/session/search` read this index from
        // outside the app, and nothing else refreshed it while the app ran — only launch and opening
        // the search panel did, so after a day of uptime the history an agent was reading had
        // stopped a day ago. An unchanged corpus costs ~0.1 s off the main thread.
        let reindex = Timer(timeInterval: 300, repeats: true) { _ in SearchIndex.refresh() }
        RunLoop.main.add(reindex, forMode: .common)
        state.updates.check()        // one GET, at most every six hours; off via logging.json
        let w = EventWatcher()
        w.onEvent = { [weak state] ev in
            Task { @MainActor in state?.handleHookEvent(ev) }
        }
        w.start()
        return w
    }

    /// Tear down web servers and save, leaving the tmux sessions running.
    static func stop(_ state: AppState) {
        // Before anything else: a window disappearing from here on is teardown, not someone closing
        // a terminal, and must not take the session with it (see AppState.handleWindowClosed).
        state.isQuitting = true
        // Terminals outlive the app by default — that is what lets a long run continue across a
        // relaunch or an update. Only quit with the fleet when the user asked for it, and never
        // when this "quit" is the self-updater handing off to the installer.
        if state.closeTerminalsOnQuit && !SelfUpdate.isHandingOff {
            state.closeAllTerminals(reason: "quit")
        }
        state.saveNow()          // saves are debounced now; this is the one that must not be missed
        state.web.stop()
        state.remote.stopAll()
        AppAudit.shared.stop(reason: "quit")   // flushes the buffer before the process goes away
    }
}

/// FleetView on a Mac with no screen to draw on — reached only over SSH, like the Mac mini.
///
/// NSApplication cannot finish launching there: with no window server `applicationDidFinishLaunching`
/// never fires, so the process sits in its event loop having started nothing — no dashboard, no
/// hooks, no `~/.fleetview`. Measured on the mini, not assumed. This runs everything that is not a
/// window instead: the board is the web dashboard, terminals are tmux sessions with nobody attached
/// (HeadlessTerminal), and `project-manager` drives it exactly as it drives a desktop instance.
///
/// Start it from an SSH login rather than from launchd. Files an agent opens are checked by TCC
/// against the process responsible for it; from SSH that is the remote-login service, which on the
/// mini already has Full Disk Access, while a launchd job would be FleetView itself — which nobody
/// can grant anything to without a screen.
@MainActor
enum Headless {
    private(set) static var active = false
    private static var state: AppState?
    private static var watcher: EventWatcher?
    private static var signals: [DispatchSourceSignal] = []

    /// `--headless`, or no GUI session to put a window in. `--gui` overrides the detection.
    nonisolated static var wanted: Bool {
        let args = CommandLine.arguments
        if args.contains("--gui") { return false }
        if args.contains("--headless") { return true }
        return CGSessionCopyCurrentDictionary() == nil
    }

    static func run() -> Never {
        active = true
        let state = AppState()
        self.state = state
        watcher = AppStartup.start(state)
        state.reconnectLiveTerminals()      // reattach terminals whose tmux sessions survived
        let line = "FleetView headless (\(FV.version)) — dashboard on port \(state.web.port)"
        FV.log(line)
        print(line)
        fflush(stdout)
        // Stop the way Quit does, so state is saved and the sessions are left running: a restart
        // is `kill` and start again, and the terminals survive it as they survive a relaunch.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    FV.log("headless: signal \(sig), stopping")
                    if let s = Headless.state { AppStartup.stop(s) }
                    exit(0)
                }
            }
            src.resume()
            signals.append(src)
        }
        RunLoop.main.run()
        exit(0)
    }
}
