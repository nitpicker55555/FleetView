import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var window: NSWindow!
    var watcher: EventWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.load()
        setupMenu()

        // Live status via Claude Code hooks (reversible; no-ops for terminals FleetView didn't launch).
        HookInstaller.install()
        ShellIntegration.install()   // zsh command capture for FleetView-launched terminals
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
        win.makeKeyAndOrderFront(nil)
        self.window = win
        NSApp.activate(ignoringOtherApps: true)
    }

    // Closing the dashboard while terminal windows remain keeps the app alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
        appMenu.addItem(withTitle: "About FleetView", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FleetView", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        let uninstall = NSMenuItem(title: "Uninstall Claude Status Hooks", action: #selector(uninstallHooks), keyEquivalent: "")
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

        NSApp.mainMenu = mainMenu
    }

    @objc private func uninstallHooks() {
        HookInstaller.uninstall()
        let a = NSAlert()
        a.messageText = "Claude status hooks removed"
        a.informativeText = "FleetView's hooks were removed from ~/.claude/settings.json. Live status will stop updating until you relaunch FleetView."
        a.runModal()
    }

    @objc private func revealSupport() {
        FV.ensureSupportDir()
        NSWorkspace.shared.open(FV.supportDir)
    }
}
