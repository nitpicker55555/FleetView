import AppKit
import SwiftTerm

/// One independent terminal window (its own NSWindow hosting a SwiftTerm view), running an
/// interactive login shell in the project cwd. The dashboard shows a card per controller.
@MainActor
final class TerminalWindowController: NSObject, NSWindowDelegate, @preconcurrency LocalProcessTerminalViewDelegate {
    let termId: UUID
    private(set) var window: NSWindow!
    private let termView: LocalProcessTerminalView
    private var keyMonitor: Any?

    var onExit: ((UUID, Int32?) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onInterrupt: ((UUID) -> Void)?   // user pressed Escape (Claude's interrupt key)

    init(termId: UUID, title: String, cwd: String, autoRunClaude: Bool, port: Int?, tmux: TmuxSpec?) {
        self.termId = termId
        self.termView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 920, height: 560))
        super.init()

        termView.processDelegate = self

        // SwiftTerm's default env intentionally omits PATH, so we run a *login* shell to
        // restore the user's PATH (needed for `claude`), and inject our identity markers.
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        env.append("FLEETVIEW_TERM_ID=\(termId.uuidString)")
        if let port { env.append("FLEETVIEW_PORT=\(port)") }
        env.append(contentsOf: ShellIntegration.env())   // zsh: capture shell commands via preexec

        let shell = FV.userShell
        let shellLeaf = (shell as NSString).lastPathComponent

        if let tmux {
            // Run the shell *inside* a tmux session so the web view (ttyd) can attach to the same
            // session and mirror it. This local window is just one attached client. The pane command
            // is passed as separate argv (tmux exec's it directly, no shell re-splitting), and we
            // wrap it in `env` so our identity vars reach the shell on any tmux version.
            var args = ["-L", tmux.socket, "-f", tmux.confPath,
                        "new-session", "-A", "-s", tmux.session, "-c", cwd, "-x", "200", "-y", "50",
                        "/usr/bin/env"]
            for e in env where !e.hasPrefix("TERM=") { args.append(e) }   // tmux owns TERM in the pane
            args.append(contentsOf: [shell, "-i", "-l"])
            termView.startProcess(executable: tmux.tmuxPath,
                                  args: args,
                                  environment: env,
                                  currentDirectory: cwd)
        } else {
            termView.startProcess(executable: shell,
                                  args: ["-i", "-l"],
                                  environment: env,
                                  execName: "-\(shellLeaf)",
                                  currentDirectory: cwd)
        }

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = title
        win.tabbingMode = .disallowed
        win.contentView = termView
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 480, height: 300)
        self.window = win

        // Report Escape (Claude's interrupt) so a stuck "working" card clears immediately. A local
        // monitor is used because SwiftTerm's keyDown isn't overridable; the key still reaches the shell.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {   // 53 = Escape
                MainActor.assumeIsolated {
                    if let self, event.window === self.window { self.onInterrupt?(self.termId) }
                }
            }
            return event
        }

        if autoRunClaude {
            // Type `claude` into the ready interactive shell — same as the user does by hand.
            // A touch longer under tmux, which needs a moment to spin up the session + pane.
            DispatchQueue.main.asyncAfter(deadline: .now() + (tmux == nil ? 0.7 : 1.1)) { [weak self] in
                self?.type("claude\r")
            }
        }
    }

    func show(cascadeFrom point: inout NSPoint) {
        window.makeKeyAndOrderFront(nil)
        point = window.cascadeTopLeft(from: point)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Bring this terminal window to the visual top (requirement #7).
    func raise() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func setTitle(_ title: String) { window.title = title }

    func type(_ s: String) {
        let bytes = Array(s.utf8)
        termView.send(source: termView, data: bytes[...])
    }

    func closeWindow() { window.close() }

    // MARK: LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}   // keep our fixed name
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onExit?(termId, exitCode) }

    // MARK: NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        onClose?(termId)
    }
}
