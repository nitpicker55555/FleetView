import Foundation
import SwiftTerm

/// What AppState needs from whatever is holding a terminal open: a desktop window, or nothing.
///
/// AppState talks to a terminal through exactly these calls, which is what lets a machine with no
/// screen — the Mac mini reached only over SSH — run the same board: its terminals are tmux sessions
/// with nobody attached, driven from the web dashboard and `project-manager`.
@MainActor
protocol TerminalHost: AnyObject {
    var onExit: ((UUID, Int32?) -> Void)? { get set }
    var onClose: ((UUID) -> Void)? { get set }
    var onInterrupt: ((UUID) -> Void)? { get set }
    var onZoomed: ((Double) -> Void)? { get set }
    func show(cascadeFrom point: inout NSPoint)
    func raise()
    func setTitle(_ title: String)
    func setFontSize(_ size: Double)
    func type(_ s: String)
    func closeWindow()
}

extension TerminalWindowController: TerminalHost {}

/// A terminal with no window: the tmux session a TerminalWindowController would have attached to,
/// created detached.
///
/// The session is made exactly as the window makes it — same socket, config, size, environment and
/// login shell — so hooks, the web view and `project-manager` cannot tell the two apart, and a
/// board moved between a desktop and a headless run reattaches either way.
@MainActor
final class HeadlessTerminal: TerminalHost {
    var onExit: ((UUID, Int32?) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onInterrupt: ((UUID) -> Void)?     // no keyboard to press Escape on; the web's /key handles it
    var onZoomed: ((Double) -> Void)?

    private let termId: UUID
    private let remote: RemoteServer
    private var watch: Timer?
    private var closed = false

    /// nil when the session could not be created (tmux missing or refusing) — the caller then has no
    /// terminal to track, exactly as when a window fails to open.
    init?(termId: UUID, cwd: String, autoRunClaude: Bool, port: Int?, tmux: TmuxSpec, remote: RemoteServer) {
        self.termId = termId
        self.remote = remote
        if !remote.sessionExists(termId) {
            var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
            env.append("FLEETVIEW_TERM_ID=\(termId.uuidString)")
            if let port { env.append("FLEETVIEW_PORT=\(port)") }
            env.append(contentsOf: ShellIntegration.env())
            var args = ["-L", tmux.socket, "-f", tmux.confPath, "-u",
                        "new-session", "-d", "-s", tmux.session, "-c", cwd, "-x", "200", "-y", "50",
                        "/usr/bin/env"]
            for e in env where !e.hasPrefix("TERM=") { args.append(e) }
            args.append(contentsOf: [FV.userShell, "-i", "-l"])
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tmux.tmuxPath)
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            // Only this list, as the window passes it: FleetView's own environment is the SSH login
            // that started it, and SSH_CONNECTION and friends have no business in every pane.
            p.environment = env.reduce(into: [:]) { acc, kv in
                let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { acc[parts[0]] = parts[1] }
            }
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                FV.log("headless: tmux new-session for \(tmux.session) exited \(p.terminationStatus)")
                return nil
            }
            if autoRunClaude {
                // Same pause the window takes before typing into a fresh shell under tmux.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                    self?.type("claude\r")
                }
            }
        }
        // A window learns its shell ended from the pty closing. With no pty, the session going away
        // is the same fact — `liveSessions` is one cached list-sessions shared with /state. Its 2s
        // cache plus this interval is how late a card can be to say "exited": ~4s at worst, where
        // a 3s tick measured just over 6.
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAlive() }
        }
    }

    private func checkAlive() {
        guard !closed else { return }
        if !remote.liveSessions().contains(RemoteServer.sessionName(for: termId)) {
            watch?.invalidate()
            watch = nil
            onExit?(termId, nil)
        }
    }

    func show(cascadeFrom point: inout NSPoint) {}
    func raise() {}
    func setTitle(_ title: String) {}
    func setFontSize(_ size: Double) {}

    /// Keystrokes go where the web's Send puts them. A trailing CR is the window's way of saying
    /// "and press Enter"; tmux needs it as the separate key.
    func type(_ s: String) {
        if s.hasSuffix("\r") {
            remote.sendText(termId, text: String(s.dropLast()), enter: true)
        } else {
            remote.sendText(termId, text: s, enter: false)
        }
    }

    /// What closing the window does: AppState's onClose kills the session.
    func closeWindow() {
        guard !closed else { return }
        closed = true
        watch?.invalidate()
        watch = nil
        onClose?(termId)
    }
}
