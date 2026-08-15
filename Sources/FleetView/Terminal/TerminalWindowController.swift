import AppKit
import SwiftTerm

/// The terminal view, subclassed for the things that have to happen at view level.
///
/// Following the system appearance needs both halves: `NSView` is the lowest thing already told
/// about a flip (SwiftTerm holds resolved colours, not dynamic ones, so nothing repaints on its
/// own), and this is where pty bytes enter the emulator — the only place an agent's hard-coded
/// 24-bit colours can still be reached. Pinch-to-zoom and file drops are here for the same reason:
/// both are delivered to the view under the pointer.
private final class ThemedTerminalView: LocalProcessTerminalView {
    var onAppearanceChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    /// Rescue the colours of a dark-themed agent painting into a light window (see `TerminalInk`).
    /// Off in dark, where the stream is not touched at all.
    var adaptsInk = false {
        didSet {
            guard adaptsInk != oldValue, let held = ink.flushPending() else { return }
            // Whatever half-sequence the adapter was holding has to reach the emulator now, or the
            // bytes that complete it arrive orphaned and print as text.
            feed(byteArray: held[...])
        }
    }
    private var ink = TerminalInk()

    /// Live pinch, reported as a point size. Only this window follows along while the fingers are
    /// moving; `onZoomEnded` is where the rest of the fleet catches up.
    var onZoom: ((Double) -> Void)?
    var onZoomEnded: (() -> Void)?
    private var zoomBase: Double = 0
    private var zoomScale: Double = 1

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            zoomBase = Double(font.pointSize)
            zoomScale = 1
        case .changed:
            // `.began` is not guaranteed — a gesture already in flight when the window takes focus
            // arrives mid-stream, and without this the first pinch would scale from a size of zero.
            if zoomBase == 0 { zoomBase = Double(font.pointSize); zoomScale = 1 }
            zoomScale += Double(event.magnification)
            // Fold the size limits back into the scale. Left to run free, pinching hard past a limit
            // banks up scale that then has to be pinched back off before the text moves at all.
            let target = min(TerminalWindowController.fontSizeRange.upperBound,
                             max(TerminalWindowController.fontSizeRange.lowerBound,
                                 zoomBase * zoomScale))
            zoomScale = target / zoomBase
            onZoom?(target)
        case .ended, .cancelled:
            zoomBase = 0
            onZoomEnded?()
        default:
            break
        }
    }

    // MARK: File drop

    /// Dropping files types their paths, the way Terminal.app does it. SwiftTerm registers no
    /// dragged types of its own, so none of this displaces existing behaviour.
    ///
    /// The path is *typed*, never executed — no newline is sent. A drop therefore lands wherever
    /// the cursor already is: a shell prompt, or an agent's input box mid-sentence. Deciding what
    /// the path is for belongs to the person, not to the drop.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = droppedURLs(sender).map { Self.shellQuoted($0.path) }
        guard !paths.isEmpty else { return false }
        // Trailing space so the next thing typed does not fuse onto the path; multiple files come
        // through as one drop and read as separate arguments.
        send(txt: paths.joined(separator: " ") + " ")
        return true
    }

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts)
            as? [URL] ?? []
    }

    /// Quote a path unless it is plainly safe to leave bare.
    ///
    /// Spaces are the obvious case; an apostrophe in a folder name ("Kim's Mac") is the one that
    /// breaks naive quoting, so a `'` is closed, escaped and reopened — the only form every POSIX
    /// shell agrees on. Anything non-ASCII (CJK paths are everywhere here) is quoted too rather
    /// than reasoned about.
    private static func shellQuoted(_ path: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")
        if !path.isEmpty, path.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `LocalProcess` delivers on the main queue (it is constructed without a queue of its own), so
    /// `ink` is only ever touched from one thread — the same one `adaptsInk` is set on.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        guard adaptsInk, let adapted = ink.adapt(slice) else {
            super.dataReceived(slice: slice)
            return
        }
        feed(byteArray: adapted[...])
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
    /// A pinch finished on this window, at this point size — the fleet's cue to follow.
    var onZoomed: ((Double) -> Void)?

    /// Read from the system rather than written down, because it is the same expression SwiftTerm
    /// builds its own default font from — pinning a number here would silently stop meaning
    /// "the default" the day the two disagree.
    static let defaultFontSize = Double(NSFont.systemFontSize)
    /// Below 8 the glyphs stop being letters; above 36 an 80-column line no longer fits a window
    /// anybody would open. Both ends also bound how far one pinch can run away with the size.
    static let fontSizeRange: ClosedRange<Double> = 8...36

    private(set) var fontSize: Double = TerminalWindowController.defaultFontSize

    /// How wide a new terminal window opens.
    ///
    /// Derived from the font instead of fixed, because what a terminal is judged by is columns and a
    /// fixed 920pt quietly meant fewer of them as the font grew — at 24pt it came to about 64, which
    /// is where the wrapping came from. 80 is the width terminal output is written for. Clamped to
    /// the screen, so a large font cannot open a window wider than the display it appears on.
    static func defaultWidth(for fontSize: Double) -> Double {
        let cell = fontSize * 0.6      // monospace advance is ~0.6em in the fonts SwiftTerm picks
        let room = (NSScreen.main?.visibleFrame.width ?? 1440) - 100
        return max(920, min(cell * 80 + 28, room))
    }

    init(termId: UUID, title: String, cwd: String, autoRunClaude: Bool, port: Int?, tmux: TmuxSpec?,
         fontSize: Double) {
        self.termId = termId
        self.termView = ThemedTerminalView(
            frame: NSRect(x: 0, y: 0, width: Self.defaultWidth(for: fontSize), height: 560))
        super.init()

        termView.processDelegate = self
        termView.onAppearanceChange = { [weak self] in
            MainActor.assumeIsolated { self?.applyAppearance() }   // AppKit only calls this on main
        }
        applyAppearance()
        // Before `startProcess`, which sizes the pty from the terminal's columns and rows — those
        // come from the cell size, so a font applied afterwards would leave the child believing in
        // a window that no longer exists.
        setFontSize(fontSize)
        termView.onZoom = { [weak self] size in
            MainActor.assumeIsolated { self?.setFontSize(size) }
        }
        termView.onZoomEnded = { [weak self] in
            MainActor.assumeIsolated { guard let self else { return }; self.onZoomed?(self.fontSize) }
        }

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

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                               width: Self.defaultWidth(for: fontSize), height: 560),
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
        termView.adaptsInk = palette.rescuesDarkThemedInk
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

    /// Resize the text. The window keeps its frame and gains or loses columns and rows instead —
    /// which is what a terminal is expected to do, and what makes this reach the child process:
    /// SwiftTerm recomputes the grid from the new cell size and that lands as a `TIOCSWINSZ`.
    ///
    /// Rounded to whole points, and skipped when nothing changes: a pinch delivers deltas at screen
    /// refresh rate, and every one of them would otherwise be a font rebuild, a grid resize and a
    /// `SIGWINCH` into a full-screen agent that redraws on each.
    func setFontSize(_ size: Double) {
        let clamped = min(Self.fontSizeRange.upperBound,
                          max(Self.fontSizeRange.lowerBound, size.rounded()))
        guard clamped != fontSize else { return }
        fontSize = clamped
        termView.font = NSFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
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
