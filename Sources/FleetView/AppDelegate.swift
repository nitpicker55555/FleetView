import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var window: NSWindow!
    var watcher: EventWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.watcher = AppStartup.start(state)
        setupMenu()

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

    /// Unsaved edits in a file window are asked about before quitting. The self-updater has asked
    /// already, before it started the swap that is waiting for this process to go.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !SelfUpdate.isHandingOff, FileWindows.shared.hasUnsaved else { return .terminateNow }
        FileWindows.shared.settleUnsaved(reason: L(.filesUnsavedQuit)) { go in
            NSApp.reply(toApplicationShouldTerminate: go)
        }
        return .terminateLater
    }

    // Tear down web servers and the FleetView tmux server so nothing is left listening after quit.
    func applicationWillTerminate(_ notification: Notification) {
        AppStartup.stop(state)
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
        appMenu.addItem(withTitle: L(.menuAbout),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        let update = NSMenuItem(title: L(.menuCheckUpdates), action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        appMenu.addItem(update)
        let share = NSMenuItem(title: L(.menuShareSettings), action: #selector(openShareSettings), keyEquivalent: "")
        share.target = self
        appMenu.addItem(share)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L(.menuHide), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        let closeAll = NSMenuItem(title: L(.menuCloseAll), action: #selector(closeAllTerminals), keyEquivalent: "")
        closeAll.target = self
        appMenu.addItem(closeAll)
        let clear = NSMenuItem(title: L(.menuClearBoard), action: #selector(clearBoard), keyEquivalent: "")
        clear.target = self
        appMenu.addItem(clear)
        appMenu.addItem(.separator())
        let uninstall = NSMenuItem(title: L(.menuUninstallHooks), action: #selector(uninstallHooks), keyEquivalent: "")
        uninstall.target = self
        appMenu.addItem(uninstall)
        let reveal = NSMenuItem(title: L(.menuRevealSupport), action: #selector(revealSupport), keyEquivalent: "")
        reveal.target = self
        appMenu.addItem(reveal)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L(.menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L(.menuEdit))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: L(.menuCut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L(.menuCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L(.menuPaste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L(.menuSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // ⌘K is bound in the view too; the menu item is what makes it discoverable.
        let search = NSMenuItem(title: L(.menuSearch), action: #selector(openSearch), keyEquivalent: "k")
        search.target = self
        editMenu.addItem(search)

        // Terminal text size. The gesture for it is a pinch on the terminal window itself; these
        // exist so it is discoverable at all, and so there is a way back to the default size that
        // does not involve pinching until it looks about right.
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: L(.menuView))
        viewItem.submenu = viewMenu
        let bigger = NSMenuItem(title: L(.menuFontBigger), action: #selector(terminalFontBigger), keyEquivalent: "+")
        bigger.target = self
        viewMenu.addItem(bigger)
        let smaller = NSMenuItem(title: L(.menuFontSmaller), action: #selector(terminalFontSmaller), keyEquivalent: "-")
        smaller.target = self
        viewMenu.addItem(smaller)
        let actual = NSMenuItem(title: L(.menuFontActual), action: #selector(terminalFontActual), keyEquivalent: "0")
        actual.target = self
        viewMenu.addItem(actual)

        NSApp.mainMenu = mainMenu
    }

    // In front of a file window the same keys size its text instead: changing every terminal's font
    // from a window that shows none of them would be a surprise.
    @objc private func terminalFontBigger() {
        if FileWindows.shared.zoom(NSApp.keyWindow, by: 1) { return }
        state.setTerminalFontSize(state.terminalFontSize + 1)
    }
    @objc private func terminalFontSmaller() {
        if FileWindows.shared.zoom(NSApp.keyWindow, by: -1) { return }
        state.setTerminalFontSize(state.terminalFontSize - 1)
    }
    @objc private func terminalFontActual() {
        if FileWindows.shared.zoom(NSApp.keyWindow, by: nil) { return }
        state.setTerminalFontSize(TerminalWindowController.defaultFontSize)
    }

    @objc private func uninstallHooks() {
        HookInstaller.uninstall()
        CodexHookInstaller.uninstall()
        let a = NSAlert()
        a.messageText = L(.hooksRemovedTitle)
        a.informativeText = L(.hooksRemovedBody)
        a.runModal()
    }

    /// Stop the whole fleet. Confirmed first, and the confirmation says what survives: the cards
    /// stay and reopen into their conversations, which is the difference between this and Remove.
    @objc private func closeAllTerminals() {
        BoardActions.confirmCloseAll(state, reason: "menu")
    }

    @objc private func clearBoard() {
        BoardActions.confirmClear(state, reason: "menu")
    }

    @objc private func openShareSettings() {
        NSApp.activate(ignoringOtherApps: true)
        state.dialog = .shareSettings
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
