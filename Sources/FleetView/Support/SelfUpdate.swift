import AppKit
import Foundation

/// Installs a newer FleetView over the running one.
///
/// The whole design follows from one constraint: **the thing being replaced is the thing doing the
/// replacing**. An app cannot delete its own bundle and then start the new one, so the swap is
/// handed to a detached shell script that waits for this process to exit, and this process quits.
/// From there the script owns the outcome, which is why the old bundle is *moved aside* rather than
/// deleted: if the new one fails to install, or installs but never appears in the process list, the
/// script puts the old bundle back and launches it. The only path that deletes anything is the one
/// where a new instance has been seen running.
///
/// Everything that can be checked before the point of no return is checked before it — the download
/// is a real zip, it contains an app bundle, that bundle says it is the version we were promised,
/// and its code signature verifies. A corrupt download must not be able to take out a working
/// install, and after the swap begins there is nobody left to tell.
///
/// Quitting is safe by construction: terminals live in tmux on the `fleetview` socket and the
/// status hooks re-attach on launch, so the fleet outlives the app that draws it.
@MainActor
enum SelfUpdate {

    /// This quit is a relaunch, not a shutdown. It exists because `closeTerminalsOnQuit` would
    /// otherwise read the handoff as the user quitting and stop the whole fleet — halfway through
    /// installing an update whose entire premise (see above) is that the fleet survives it.
    private(set) static var isHandingOff = false

    private static var updateDir: URL { FV.supportDir.appendingPathComponent("update", isDirectory: true) }
    private static var stagedDir: URL { updateDir.appendingPathComponent("staged", isDirectory: true) }
    private static var backupApp: URL { updateDir.appendingPathComponent("previous.app") }
    private static var script: URL { updateDir.appendingPathComponent("swap.sh") }
    private static var log: URL { FV.supportDir.appendingPathComponent("update.log") }

    /// Why this install cannot be attempted. Each one is a thing the user can act on, so none of
    /// them is folded into a generic failure.
    enum Blocked: LocalizedError {
        case notABundle(String)
        case notWritable(String)
        case noAsset

        var errorDescription: String? {
            switch self {
            case .notABundle(let p):
                return L(.updNotABundle(p))
            case .notWritable(let p):
                return L(.updNotWritable(p))
            case .noAsset:
                return L(.updNoAsset)
            }
        }
    }

    /// Can this install run at all? Checked before the offer is made, so the button is not shown
    /// when pressing it could only fail.
    static func precheck(_ release: UpdateCheck.Release) -> Blocked? {
        guard release.assetURL != nil else { return .noAsset }
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return .notABundle(bundle.path) }
        let parent = bundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return .notWritable(parent.path)
        }
        return nil
    }

    // MARK: - Install

    static func install(_ release: UpdateCheck.Release, updates: UpdateCheck) {
        if let blocked = precheck(release) {
            // Nothing has started yet and the alert that offered the install is still the context
            // the user is in, so this one stays an alert. Every failure past this point is a row.
            alert(blocked.localizedDescription)
            return
        }
        guard let assetURL = release.assetURL, let url = URL(string: assetURL) else { return }
        // One at a time. Two installs racing for the same bundle is the one way this dance can end
        // with no FleetView on the Mac at all.
        guard updates.status == nil else { return }
        let target = Bundle.main.bundleURL
        updates.status = L(.updStatus(release.version))

        let jobs = BackgroundJobs.shared
        let job = jobs.start(.update, title: L(.updJobTitle(release.version)), detail: L(.updConnecting))
        let download = Download(url: url, version: release.version) { fraction, detail in
            jobs.progress(job, fraction, detail)
        } done: { result in
            switch result {
            case .failure(let error):
                // A cancel already took the row away as it happened; there is nothing to report.
                if error is CancellationError { updates.status = nil; return }
                fail(error.localizedDescription, job: job, updates: updates)
            case .success(let zip):
                // Past the download there is nothing left to stop that would not leave a
                // half-installed app behind, so the ✕ goes; what remains is seconds of local work.
                jobs.setCancel(job, nil)
                jobs.progress(job, nil, L(.updVerifying))
                Task.detached {
                    do {
                        let staged = try stage(zip: zip, expecting: release.version)
                        await MainActor.run {
                            // Headless has no file windows and nobody to ask: straight to the swap.
                            if Headless.active {
                                handOff(staged: staged, target: target, updates: updates, job: job)
                                return
                            }
                            // Before swap.sh exists: it waits only 30 s for this process to quit, and
                            // a question asked after it starts would let the update give up silently.
                            // Unsaved edits in a file window are asked about now; staying keeps the
                            // staged app, so trying again later starts from here.
                            FileWindows.shared.settleUnsaved(reason: L(.filesUnsavedUpdate)) { go in
                                if go {
                                    handOff(staged: staged, target: target, updates: updates, job: job)
                                } else {
                                    fail(L(.updUnsavedCancelled), job: job, updates: updates)
                                }
                            }
                        }
                    } catch {
                        await MainActor.run {
                            fail(error.localizedDescription, job: job, updates: updates)
                        }
                    }
                }
            }
        }
        jobs.setCancel(job) {
            download.cancel()
            updates.status = nil
        }
        download.start()
    }

    /// The last lines of update.log (what swap.sh said), for `GET /update`.
    static func logTail(_ n: Int) -> [String] {
        guard let s = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return Array(s.split(separator: "\n").suffix(n).map(String.init))
    }

    /// Install the release currently on offer without asking — the remote path (`GET /update?install=`,
    /// `project-manager update --install`), which is the only way a headless FleetView can update at
    /// all and the way to update a Mac nobody is sitting at. `version` has to name what is on offer,
    /// so a request cannot install something other than what the caller just saw. nil = started.
    static func installRemotely(_ version: String, updates: UpdateCheck) -> String? {
        guard let r = updates.available else { return "nothing newer is on offer (check first)" }
        guard UpdateCheck.normalise(version) == r.version else { return "on offer is \(r.version), not \(version)" }
        if updates.status != nil { return "an update is already running" }
        if let b = precheck(r) { return b.localizedDescription }
        FV.log("self-update: remote install of \(r.version) requested")
        install(r, updates: updates)
        return nil
    }

    /// How the new bundle gets started once it is in place: the way this one was. A desktop app is
    /// opened; a headless one is started with the same arguments, and when it was running inside
    /// tmux (the only way the mini runs it — see Headless) in a tmux session of the same name on the
    /// same server, so it keeps the responsible process TCC grants were made to. A placeholder
    /// session keeps that server alive across the gap: if this was its last session, the server
    /// would exit with it and the relaunch would have to start a new one from launchd.
    private static func relaunchArgs() -> [String] {
        guard Headless.active else { return ["open", "", ""] }
        let env = ProcessInfo.processInfo.environment
        // The pane this process runs in names its session; without -t tmux would answer with whichever
        // session was used last, which on a shared server is somebody else's.
        if let t = env["TMUX"], let socket = t.split(separator: ",").first.map(String.init), !socket.isEmpty,
           let pane = env["TMUX_PANE"], !pane.isEmpty,
           let session = tmux(socket, ["display-message", "-p", "-t", pane, "#S"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !session.isEmpty {
            _ = tmux(socket, ["new-session", "-d", "-s", holdSession, "sleep 900"])
            return ["tmux", socket, session]
        }
        return ["nohup", "", ""]
    }

    static let holdSession = "fv-update-hold"

    private static func tmux(_ socket: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "TMUX")
        p.environment = env
        p.arguments = ["tmux", "-S", socket] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    /// Unpack and vet the download. Runs off the main actor — everything here is subprocesses and
    /// file IO, and all of it happens *before* anything on disk is touched.
    private nonisolated static func stage(zip: URL, expecting version: String) throws -> URL {
        let staged = FV.supportDir.appendingPathComponent("update/staged", isDirectory: true)
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, staged.path]) else {
            throw Failure(L(.updNotZip))
        }
        let app = staged.appendingPathComponent("FleetView.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw Failure(L(.updNoApp))
        }
        // The zip says who it is. A release whose tag and bundle disagree is a mistake somewhere,
        // and installing it would leave the app claiming a version it is not.
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let got = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? ""
        guard UpdateCheck.normalise(got) == UpdateCheck.normalise(version) else {
            throw Failure(L(.updVersionMismatch(got.isEmpty ? L(.updUnknown) : got, version)))
        }
        // Downloads arrive quarantined; left in place the replacement app cannot launch without the
        // right-click dance, which would look exactly like a failed update.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        // FleetView is ad-hoc signed, so this proves integrity rather than provenance — which is
        // precisely the question here: did the bytes survive the network intact?
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else {
            throw Failure(L(.updBadSignature))
        }
        try? FileManager.default.removeItem(at: zip)
        return staged
    }

    /// The point of no return: write the swap script, launch it detached, and quit so it can work.
    private static func handOff(staged: URL, target: URL, updates: UpdateCheck, job: UUID) {
        updates.status = L(.updInstalling)
        BackgroundJobs.shared.progress(job, 1, L(.updInstallingRestart))
        do {
            try FileManager.default.createDirectory(at: updateDir, withIntermediateDirectories: true)
            try swapScript.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            fail(L(.updScriptPrepare(error.localizedDescription)), job: job, updates: updates)
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunch = relaunchArgs() + (Headless.active ? Array(CommandLine.arguments.dropFirst()) : [])
        let cmd = "nohup /bin/bash \(q(script.path)) \(pid) \(q(staged.path)) "
                + "\(q(target.path)) \(q(backupApp.path)) \(q(log.path)) "
                + relaunch.map(q).joined(separator: " ") + " >/dev/null 2>&1 &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        do { try p.run() } catch {
            fail(L(.updScriptLaunch(error.localizedDescription)), job: job, updates: updates)
            return
        }
        // `&` detaches it: /bin/sh exits immediately and bash is reparented to launchd, so it
        // survives the quit it is waiting for.
        FV.log("self-update: handed off to swap.sh (pid \(pid) → \(target.path), relaunch \(relaunch.first ?? "open"))")
        isHandingOff = true
        if Headless.active { Headless.quitForUpdate() }
        NSApp.terminate(nil)
    }

    /// Where an update failure goes now: the job row, not a modal alert. The install runs while the
    /// user is doing something else — that is the entire point of moving it off the main path — and
    /// a dialog seizing the keyboard mid-sentence is the behaviour being removed. The row is red, it
    /// keeps the reason, and it stays until it is dismissed rather than vanishing with an OK button.
    private static func fail(_ why: String, job: UUID?, updates: UpdateCheck) {
        updates.status = nil
        FV.log("self-update failed: \(why)")
        guard let job else { alert(why); return }
        BackgroundJobs.shared.fail(job, why + L(.updSeeLog),
                                   recoverLabel: L(.updOpenReleasePage)) {
            NSWorkspace.shared.open(releasesPage)
        }
    }

    private static let releasesPage =
        URL(string: "https://github.com/nitpicker55555/FleetView/releases")!

    /// The one failure still worth interrupting for: it lands in the same click as the alert that
    /// offered the install, so there is no background work yet for it to be a row on.
    private static func alert(_ why: String) {
        let a = NSAlert()
        a.messageText = L(.updFailedTitle)
        a.informativeText = why + L(.updSeeLogBody)
        a.addButton(withTitle: L(.ok))
        a.addButton(withTitle: L(.updOpenReleasePage))
        if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(releasesPage) }
    }

    // MARK: - Helpers

    fileprivate struct Failure: LocalizedError {
        let why: String
        init(_ w: String) { why = w }
        var errorDescription: String? { why }
    }

    private nonisolated static func run(_ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Written to disk rather than kept inline so a failed update can be read, re-run and reasoned
    /// about after the fact — by which time the app that produced it is gone.
    private static let swapScript = """
    #!/bin/bash
    # Written by FleetView's self-update. Runs detached, after the app it replaces has quit.
    #   swap.sh <pid> <staged-dir> <target.app> <backup.app> <log> <mode> <tmux-socket> <tmux-session> [args…]
    #   mode: open (the desktop app) · tmux (headless, back into the same session on the same server)
    #         · nohup (headless, not in tmux)
    set -u
    PID="$1"; STAGED="$2"; TARGET="$3"; BACKUP="$4"; LOG="$5"
    MODE="${6:-open}"; SOCKET="${7:-}"; SESSION="${8:-}"
    shift 8 2>/dev/null || shift $#
    ARGS=("$@")
    NEW="$STAGED/FleetView.app"
    exec >>"$LOG" 2>&1
    echo "--- $(date '+%Y-%m-%d %H:%M:%S') swap pid=$PID target=$TARGET mode=$MODE ${SESSION:+session=$SESSION}"

    tm() { env -u TMUX tmux -S "$SOCKET" "$@"; }
    launch() {
      case "$MODE" in
        tmux)
          # The old session ends with the app it ran; wait for its name to be free, else use another.
          name="$SESSION"
          for _ in $(seq 1 20); do tm has-session -t "=$name" 2>/dev/null || break; sleep 0.5; done
          tm has-session -t "=$name" 2>/dev/null && name="$SESSION-updated"
          tm new-session -d -s "$name" "exec $(printf '%q ' "$TARGET/Contents/MacOS/FleetView" ${ARGS[@]+"${ARGS[@]}"})"
          ;;
        nohup) nohup "$TARGET/Contents/MacOS/FleetView" ${ARGS[@]+"${ARGS[@]}"} >/dev/null 2>&1 & ;;
        *) open -a "$TARGET" ;;
      esac
    }
    unhold() { [ "$MODE" = tmux ] && tm kill-session -t "=fv-update-hold" 2>/dev/null; true; }

    # The app has to be gone before its bundle moves out from under it. If it never exits, nothing
    # has been touched yet and the safest thing is to change nothing.
    for _ in $(seq 1 60); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$PID" 2>/dev/null; then
      echo "old instance never exited — leaving the install alone"; exit 1
    fi

    restore() {
      echo "rolling back to the previous bundle"
      rm -rf "$TARGET"
      mv "$BACKUP" "$TARGET" && launch
      unhold
      exit 1
    }

    # Aside, not away: this is the copy that comes back if anything below fails.
    rm -rf "$BACKUP"
    mv "$TARGET" "$BACKUP" || { echo "could not move the old bundle aside"; exit 1; }

    ditto "$NEW" "$TARGET" || restore
    launch || restore

    # Installing is not succeeding. A bundle that copies cleanly and then cannot start is the exact
    # failure this dance exists to survive, so the old one stays until a new process is seen.
    started=""
    for _ in $(seq 1 30); do
      # Anchored: a tmux server started with `tmux new-session … FleetView --headless` carries the same
      # path in its own command line, and would count as the new app starting when it did not.
      pgrep -f "^$TARGET/Contents/MacOS/FleetView" >/dev/null 2>&1 && { started=1; break; }
      sleep 0.5
    done
    [ -n "$started" ] || restore

    echo "updated to $(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
    unhold
    rm -rf "$BACKUP" "$STAGED"
    """
}

/// The download, with a delegate so that it can say how far along it is.
///
/// `URLSession.shared.downloadTask(with:completionHandler:)` reports nothing at all until the file
/// has landed, which is exactly the silence this change exists to remove — `didWriteData` only
/// arrives on the delegate form. It runs its own session because a session retains its delegate
/// until it is invalidated, and `URLSession.shared` can never be; the cycle between the two is what
/// keeps this object alive for the length of the download, and `finishTasksAndInvalidate` is what
/// breaks it afterwards.
private final class Download: NSObject, URLSessionDownloadDelegate {
    private let url: URL
    private let version: String
    private let onProgress: @MainActor (Double?, String) -> Void
    private let onDone: @MainActor (Result<URL, Error>) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var saved: URL?
    private var settled = false
    /// A slow line (release assets crawl at ~35 KB/s from some networks) stalls now and then; a stall
    /// used to fail the whole update. Picks up where it stopped, a few times, before giving up.
    private var attempts = 0
    private static let maxAttempts = 5

    init(url: URL, version: String,
         progress: @escaping @MainActor (Double?, String) -> Void,
         done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        self.url = url
        self.version = version
        self.onProgress = progress
        self.onDone = done
        super.init()
    }

    func start() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // A server that sends no Content-Length reports -1 here, and a bar computed from that runs
        // backwards — so the spinner stays and the byte counter carries the news instead.
        let known = totalBytesExpectedToWrite > 0
        let fraction = known ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        let detail = known ? "\(Self.mb(totalBytesWritten)) / \(Self.mb(totalBytesExpectedToWrite))"
                           : L(.updDownloaded(Self.mb(totalBytesWritten)))
        Task { @MainActor [onProgress] in onProgress(fraction, detail) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // This file is deleted the moment the method returns, so the move happens here and not
        // after a hop to the main actor.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            settle(.failure(SelfUpdate.Failure(L(.updHTTP(http.statusCode)))))
            return
        }
        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetView-\(version).zip")
        try? FileManager.default.removeItem(at: zip)
        do {
            try FileManager.default.moveItem(at: location, to: zip)
            saved = zip
        } catch {
            settle(.failure(SelfUpdate.Failure(L(.updSaveFailed(error.localizedDescription)))))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let ns = error as NSError
            let cancelled = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
            if !cancelled, !settled, attempts + 1 < Self.maxAttempts, ns.domain == NSURLErrorDomain {
                attempts += 1
                let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                let n = attempts
                Task { @MainActor [onProgress] in onProgress(nil, L(.updConnecting) + " (\(n + 1))") }
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(2 * attempts)) { [weak self] in
                    guard let self, !self.settled else { return }
                    let next = resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: self.url)
                    self.task = next
                    next.resume()
                }
                return
            }
            settle(.failure(cancelled ? CancellationError() : error))
        } else if let saved {
            settle(.success(saved))
        } else {
            settle(.failure(SelfUpdate.Failure(L(.updNoFile))))
        }
        session.finishTasksAndInvalidate()
    }

    /// Exactly once: a failed move reports here and is then followed by a `didCompleteWithError`
    /// that knows nothing about it and would otherwise report success over the top.
    private func settle(_ result: Result<URL, Error>) {
        guard !settled else { return }
        settled = true
        Task { @MainActor [onDone] in onDone(result) }
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

/// The alerts for every update outcome, in one place because the two entry points — the menu item
/// and the pill — must not drift into offering different things.
@MainActor
enum UpdateUI {

    static func present(_ outcome: UpdateCheck.Outcome, updates: UpdateCheck) {
        let a = NSAlert()
        switch outcome {
        case .newer(let r):
            a.messageText = L(.updAvailableTitle(r.version))
            a.informativeText = L(.updCurrentVersion(FV.shortVersion))
                + (r.notes.isEmpty ? "" : "\n\n" + String(r.notes.prefix(600)))
            // The install button leads the alert only when it can actually work; otherwise the
            // release page is the honest offer, with the reason spelled out underneath.
            if let blocked = SelfUpdate.precheck(r) {
                a.informativeText += L(.updCannotInstall(blocked.localizedDescription))
                a.addButton(withTitle: L(.updViewRelease))
                a.addButton(withTitle: L(.updLater))
                if a.runModal() == .alertFirstButtonReturn { updates.openReleasePage() }
            } else {
                a.addButton(withTitle: L(.updInstall))
                a.addButton(withTitle: L(.updViewRelease))
                a.addButton(withTitle: L(.updLater))
                a.informativeText += L(.updRestartNote)
                switch a.runModal() {
                case .alertFirstButtonReturn:  SelfUpdate.install(r, updates: updates)
                case .alertSecondButtonReturn: updates.openReleasePage()
                default: break
                }
            }
            return
        case .current(let v):
            a.messageText = L(.updUpToDate)
            a.informativeText = L(.updVersionLine(v))
        case .failed(let why):
            a.messageText = L(.updCheckFailed)
            a.informativeText = why
        }
        a.runModal()
    }
}
