import AppKit
import SwiftTerm

/// A terminal view that says when the system flipped between light and dark.
///
/// SwiftTerm holds resolved colours rather than dynamic ones, so a window cannot follow the
/// appearance on its own — something has to notice the flip and repaint it. `NSView` already gets
/// told; nothing above it does.
private final class ThemedTerminalView: LocalProcessTerminalView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// One independent terminal window (its own NSWindow hosting a SwiftTerm view), running an
/// interactive login shell in the project cwd. The dashboard shows a card per controller.
@MainActor
final class TerminalWindowController: NSObject, NSWindowDelegate, @preconcurrency LocalProcessTerminalViewDelegate {
    let termId: UUID
    private(set) var window: NSWindow!
    private let termView: ThemedTerminalView
    private var keyMonitor: Any?
    /// The window is on its way out, so the process ending is our own doing rather than the shell
    /// exiting under the user. Without it the card would land on "exited" instead of "closed".
    private var closing = false

    var onExit: ((UUID, Int32?) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onInterrupt: ((UUID) -> Void)?   // user pressed Escape (Claude's interrupt key)

    init(termId: UUID, title: String, cwd: String, autoRunClaude: Bool, port: Int?, tmux: TmuxSpec?) {
        self.termId = termId
        self.termView = ThemedTerminalView(frame: NSRect(x: 0, y: 0, width: 920, height: 560))
        super.init()

        termView.processDelegate = self
        termView.onAppearanceChange = { [weak self] in
            MainActor.assumeIsolated { self?.applyAppearance() }   // AppKit only calls this on main
        }
        applyAppearance()

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
            var args = ["-L", tmux.socket, "-f", tmux.confPath, "-u",   // -u: force UTF-8 output (CJK)
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

    /// Repaint the terminal in the palette for the appearance now in effect.
    ///
    /// Order matters: the 256-colour cube is derived from the background and foreground as well as
    /// the 16 base colours, so the two anchors go in before `installColors` — which is also what
    /// triggers the full redraw, so the grid already on screen re-renders in the new palette rather
    /// than waiting for the agent to print its next line.
    private func applyAppearance() {
        let palette = TerminalPalette.matching(termView.effectiveAppearance)
        termView.nativeBackgroundColor = palette.background
        termView.nativeForegroundColor = palette.foreground
        termView.installColors(palette.ansi)
        // The layer paints everything the character grid does not: the sliver below the last row,
        // and the whole view during a live resize, when the drag outruns the redraw. SwiftTerm sets
        // it once at setup and never again, so without this a flip leaves a black band under a
        // white terminal — and a black flash on every resize.
        termView.layer?.backgroundColor = palette.background.cgColor
        // Re-assigning the same colour is not a no-op. `selectedControlColor` is already dynamic and
        // right in both appearances, but SwiftTerm stores `caretColor.cgColor` — resolved against
        // whatever appearance was current at assignment — so the caret keeps the tint it was born
        // with. Assigning it inside the new appearance re-resolves it.
        termView.effectiveAppearance.performAsCurrentDrawingAppearance {
            termView.caretColor = .selectedControlColor
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
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !closing else { return }   // we killed it; `handleWindowClosed` owns the status
        onExit?(termId, exitCode)
    }

    // MARK: NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        closing = true
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        // Closing a terminal closes the terminal. Releasing the view alone leaves the process it
        // spawned running with nothing attached to it: a headless `tmux attach` client, or (with no
        // tmux) an orphaned login shell still holding the pty. Under tmux this only ends the client
        // — AppState kills the session itself, which is what stops the agent.
        //
        // Guarded on `running`: SwiftTerm never clears `shellPid` when a child exits on its own, so
        // terminating a window whose shell already ended (`exit` at the prompt) would signal that
        // pid number again — by then it can belong to something else entirely.
        if termView.process.running { termView.process.terminate() }
        onClose?(termId)
    }
}
