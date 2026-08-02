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
                return "自动更新只能在 FleetView.app 里运行，当前是：\(p)"
            case .notWritable(let p):
                return "没有写入权限：\(p)\n把 FleetView.app 放到 /Applications 或你的用户目录下再试。"
            case .noAsset:
                return "这个 release 没有附带 .zip,只能手动下载源码构建。"
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
            fail(blocked.localizedDescription, updates: updates)
            return
        }
        guard let assetURL = release.assetURL, let url = URL(string: assetURL) else { return }
        let target = Bundle.main.bundleURL
        updates.status = "下载 \(release.version)…"

        URLSession.shared.downloadTask(with: url) { tmp, response, error in
            guard let tmp else {
                Task { @MainActor in
                    fail(error?.localizedDescription ?? "下载失败", updates: updates)
                }
                return
            }
            // The temp file is deleted when this callback returns, so it has to be moved first.
            let zip = FileManager.default.temporaryDirectory
                .appendingPathComponent("FleetView-\(release.version).zip")
            try? FileManager.default.removeItem(at: zip)
            do { try FileManager.default.moveItem(at: tmp, to: zip) } catch {
                Task { @MainActor in fail("无法保存下载文件：\(error.localizedDescription)", updates: updates) }
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Task { @MainActor in fail("下载失败：HTTP \(http.statusCode)", updates: updates) }
                return
            }
            do {
                let staged = try stage(zip: zip, expecting: release.version)
                Task { @MainActor in handOff(staged: staged, target: target, updates: updates) }
            } catch {
                Task { @MainActor in fail(error.localizedDescription, updates: updates) }
            }
        }.resume()
    }

    /// Unpack and vet the download. Runs off the main actor — everything here is subprocesses and
    /// file IO, and all of it happens *before* anything on disk is touched.
    private nonisolated static func stage(zip: URL, expecting version: String) throws -> URL {
        let staged = FV.supportDir.appendingPathComponent("update/staged", isDirectory: true)
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, staged.path]) else {
            throw Failure("下载的文件不是有效的 zip")
        }
        let app = staged.appendingPathComponent("FleetView.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw Failure("压缩包里没有 FleetView.app")
        }
        // The zip says who it is. A release whose tag and bundle disagree is a mistake somewhere,
        // and installing it would leave the app claiming a version it is not.
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let got = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? ""
        guard UpdateCheck.normalise(got) == UpdateCheck.normalise(version) else {
            throw Failure("压缩包里的版本是 \(got.isEmpty ? "未知" : got),与 release 声明的 \(version) 不一致")
        }
        // Downloads arrive quarantined; left in place the replacement app cannot launch without the
        // right-click dance, which would look exactly like a failed update.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        // FleetView is ad-hoc signed, so this proves integrity rather than provenance — which is
        // precisely the question here: did the bytes survive the network intact?
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else {
            throw Failure("下载的 app 签名校验失败，已放弃安装")
        }
        try? FileManager.default.removeItem(at: zip)
        return staged
    }

    /// The point of no return: write the swap script, launch it detached, and quit so it can work.
    private static func handOff(staged: URL, target: URL, updates: UpdateCheck) {
        updates.status = "安装中…"
        do {
            try FileManager.default.createDirectory(at: updateDir, withIntermediateDirectories: true)
            try swapScript.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            fail("无法准备安装脚本：\(error.localizedDescription)", updates: updates)
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let cmd = "nohup /bin/bash \(q(script.path)) \(pid) \(q(staged.path)) "
                + "\(q(target.path)) \(q(backupApp.path)) \(q(log.path)) >/dev/null 2>&1 &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        do { try p.run() } catch {
            fail("无法启动安装脚本：\(error.localizedDescription)", updates: updates)
            return
        }
        // `&` detaches it: /bin/sh exits immediately and bash is reparented to launchd, so it
        // survives the quit it is waiting for.
        FV.log("self-update: handed off to swap.sh (pid \(pid) → \(target.path))")
        NSApp.terminate(nil)
    }

    private static func fail(_ why: String, updates: UpdateCheck) {
        updates.status = nil
        FV.log("self-update failed: \(why)")
        let a = NSAlert()
        a.messageText = "自动更新失败"
        a.informativeText = why + "\n\n详细记录见 ~/.fleetview/update.log"
        a.addButton(withTitle: "好")
        a.addButton(withTitle: "打开发布页")
        if a.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/nitpicker55555/FleetView/releases")!)
        }
    }

    // MARK: - Helpers

    private struct Failure: LocalizedError {
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
    #   swap.sh <pid> <staged-dir> <target.app> <backup.app> <log>
    set -u
    PID="$1"; STAGED="$2"; TARGET="$3"; BACKUP="$4"; LOG="$5"
    NEW="$STAGED/FleetView.app"
    exec >>"$LOG" 2>&1
    echo "--- $(date '+%Y-%m-%d %H:%M:%S') swap pid=$PID target=$TARGET"

    # The app has to be gone before its bundle moves out from under it. If it never exits, nothing
    # has been touched yet and the safest thing is to change nothing.
    for _ in $(seq 1 60); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$PID" 2>/dev/null; then
      echo "old instance never exited — leaving the install alone"; exit 1
    fi

    restore() {
      echo "rolling back to the previous bundle"
      rm -rf "$TARGET"
      mv "$BACKUP" "$TARGET" && open -a "$TARGET"
      exit 1
    }

    # Aside, not away: this is the copy that comes back if anything below fails.
    rm -rf "$BACKUP"
    mv "$TARGET" "$BACKUP" || { echo "could not move the old bundle aside"; exit 1; }

    ditto "$NEW" "$TARGET" || restore
    open -a "$TARGET" || restore

    # Installing is not succeeding. A bundle that copies cleanly and then cannot start is the exact
    # failure this dance exists to survive, so the old one stays until a new process is seen.
    started=""
    for _ in $(seq 1 30); do
      pgrep -f "$TARGET/Contents/MacOS/FleetView" >/dev/null 2>&1 && { started=1; break; }
      sleep 0.5
    done
    [ -n "$started" ] || restore

    echo "updated to $(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
    rm -rf "$BACKUP" "$STAGED"
    """
}

/// The alerts for every update outcome, in one place because the two entry points — the menu item
/// and the pill — must not drift into offering different things.
@MainActor
enum UpdateUI {

    static func present(_ outcome: UpdateCheck.Outcome, updates: UpdateCheck) {
        let a = NSAlert()
        switch outcome {
        case .newer(let r):
            a.messageText = "FleetView \(r.version) 已发布"
            a.informativeText = "当前版本 \(FV.shortVersion)。"
                + (r.notes.isEmpty ? "" : "\n\n" + String(r.notes.prefix(600)))
            // The install button leads the alert only when it can actually work; otherwise the
            // release page is the honest offer, with the reason spelled out underneath.
            if let blocked = SelfUpdate.precheck(r) {
                a.informativeText += "\n\n（无法自动安装：\(blocked.localizedDescription)）"
                a.addButton(withTitle: "查看发布页")
                a.addButton(withTitle: "以后再说")
                if a.runModal() == .alertFirstButtonReturn { updates.openReleasePage() }
            } else {
                a.addButton(withTitle: "下载并安装")
                a.addButton(withTitle: "查看发布页")
                a.addButton(withTitle: "以后再说")
                a.informativeText += "\n\n安装完成后 FleetView 会自动重启；终端跑在 tmux 里，不受影响。"
                switch a.runModal() {
                case .alertFirstButtonReturn:  SelfUpdate.install(r, updates: updates)
                case .alertSecondButtonReturn: updates.openReleasePage()
                default: break
                }
            }
            return
        case .current(let v):
            a.messageText = "已是最新版本"
            a.informativeText = "FleetView \(v)。"
        case .failed(let why):
            a.messageText = "检查更新失败"
            a.informativeText = why
        }
        a.runModal()
    }
}
