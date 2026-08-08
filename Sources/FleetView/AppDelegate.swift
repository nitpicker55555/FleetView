import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var window: NSWindow!
    var watcher: EventWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.load()
        // Start auditing right after load, before anything can mutate state: the first snapshot is
        // the baseline every later diff is measured against.
        AppAudit.shared.start(state)
        setupMenu()

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
        state.updates.check()        // one GET, at most every six hours; off via logging.json
        let w = EventWatcher()
        w.onEvent = { [weak self] ev in
            Task { @MainActor in self?.state.handleHookEvent(ev) }
        }
        w.start()
        self.watcher = w

        let root = DashboardView().environmentObject(state)
        let hosting = NSHostingView(rootView: root)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 740),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "FleetView"
        win.center()
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("FleetViewMain")
        win.contentView = hosting
        self.window = win
        state.reconnectLiveTerminals()      // reattach terminals whose tmux sessions survived
        win.makeKeyAndOrderFront(nil)        // keep the dashboard in front of the reattached windows
        NSApp.activate(ignoringOtherApps: true)
    }

    // Closing the dashboard while terminal windows remain keeps the app alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Tear down web servers and the FleetView tmux server so nothing is left listening after quit.
    func applicationWillTerminate(_ notification: Notification) {
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        // The About panel reads the bundle's version, which is the other half of "what am I running";
        // it had no action at all, so the item was decoration.
        appMenu.addItem(withTitle: "About FleetView",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        let update = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        appMenu.addItem(update)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FleetView", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        let closeAll = NSMenuItem(title: "关闭所有终端…", action: #selector(closeAllTerminals), keyEquivalent: "")
        closeAll.target = self
        appMenu.addItem(closeAll)
        appMenu.addItem(.separator())
        let uninstall = NSMenuItem(title: "Uninstall Status Hooks (Claude + Codex)", action: #selector(uninstallHooks), keyEquivalent: "")
        uninstall.target = self
        appMenu.addItem(uninstall)
        let reveal = NSMenuItem(title: "Reveal Support Folder (~/.fleetview)", action: #selector(revealSupport), keyEquivalent: "")
        reveal.target = self
        appMenu.addItem(reveal)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FleetView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // ⌘K is bound in the view too; the menu item is what makes it discoverable.
        let search = NSMenuItem(title: "搜索对话历史…", action: #selector(openSearch), keyEquivalent: "k")
        search.target = self
        editMenu.addItem(search)

        NSApp.mainMenu = mainMenu
    }

    @objc private func uninstallHooks() {
        HookInstaller.uninstall()
        CodexHookInstaller.uninstall()
        let a = NSAlert()
        a.messageText = "Status hooks removed"
        a.informativeText = "FleetView's hooks were removed from ~/.claude/settings.json and ~/.codex/config.toml. Live status will stop updating until you relaunch FleetView."
        a.runModal()
    }

    /// Stop the whole fleet. Confirmed first, and the confirmation says what survives: the cards
    /// stay and reopen into their conversations, which is the difference between this and Remove.
    @objc private func closeAllTerminals() {
        let open = state.openTerminalCount
        let a = NSAlert()
        a.messageText = open > 0 ? "关闭 \(open) 个终端？" : "关闭所有终端？"
        a.informativeText = "正在运行的 agent 会被停止。终端卡片会留在看板上——点击卡片可以重新打开并继续原来的会话。"
        a.addButton(withTitle: "关闭全部")
        a.addButton(withTitle: "取消")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        state.closeAllTerminals(reason: "menu")
    }

    @objc private func revealSupport() {
        FV.ensureSupportDir()
        NSWorkspace.shared.open(FV.supportDir)
    }

    @objc private func openSearch() {
        state.openSearch()
    }

    /// Forced, so it ignores both the six-hour throttle and a version dismissed from the pill: the
    /// answer to a question someone just asked is never "I checked recently".
    @objc private func checkForUpdates() {
        state.updates.check(force: true) { [weak self] outcome in
            guard let self else { return }
            UpdateUI.present(outcome, updates: self.state.updates)
        }
    }
}
