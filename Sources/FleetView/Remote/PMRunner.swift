import Foundation

/// Runs `project-manager` on this machine for a caller on another one — the server half of `GET /pm`.
///
/// The history commands, `log` and `cat` read files: transcripts, the search index, memory notes.
/// From another Mac they used to refuse, because answering from the caller's own disk would describe
/// the wrong machine. Reimplementing them here in Swift would give two versions of every rule the
/// script encodes (turn numbering, injected-prompt filtering, project attribution) to keep in step,
/// so instead the script itself runs here, against this machine's files, and its output goes back.
/// Same code on both ends: the remote answer is what running it at this Mac's keyboard prints.
enum PMRunner {
    /// Everything else the CLI does already goes through the HTTP API; nothing outside this list has
    /// a reason to be started from the network. `scripts/project-manager` keeps the same list as
    /// `REMOTE_RUN`.
    static let commands: Set<String> = ["projects", "history", "session", "search", "memory", "log", "cat"]
    static let timeout: TimeInterval = 180
    /// A `cat` or a `log -c` piece is capped by the script itself; this is the backstop for anything
    /// that is not, so one request cannot hold a transcript's worth of JSON in memory.
    static let maxOutput = 32 << 20

    struct Result: Encodable {
        let code: Int32
        let stdout: String
        let stderr: String
    }

    /// The script: bundled into the app by package_app.sh; failing that, the checkout this build
    /// came from (a `swift build` run from the repo, or an install whose bundle predates bundling).
    static func scriptPath() -> String? {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL?.appendingPathComponent("project-manager").path {
            candidates.append(res)
        }
        if let repo = Bundle.main.infoDictionary?["FVSourceRepo"] as? String {
            candidates.append(repo + "/scripts/project-manager")
        }
        // A binary run straight out of .build: the checkout is some way up. Searched rather than
        // counted — `.build/release` is a symlink to `.build/<triple>/release`, so the depth depends
        // on which of the two paths it was started by, and counting three levels landed in `.build`.
        if var dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            for _ in 0..<5 {
                candidates.append(dir.appendingPathComponent("scripts/project-manager").path)
                dir.deleteLastPathComponent()
            }
        }
        candidates.append(FV.home.appendingPathComponent(".local/bin/project-manager").path)
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// Run one command. Blocks for as long as the command takes — call it off the main actor.
    static func run(argv: [String], port: Int, color: Bool, origin: String?) -> (status: String, Result) {
        guard let first = argv.first, commands.contains(first) else {
            return ("400 Bad Request",
                    Result(code: 2, stdout: "", stderr: "not something /pm runs: \(argv.first ?? "(nothing)")\n"))
        }
        guard let script = scriptPath() else {
            return ("500 Internal Server Error",
                    Result(code: 1, stdout: "", stderr: "project-manager is not installed on this machine\n"))
        }
        let python = Tooling.find("python3") ?? "/usr/bin/python3"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script] + argv
        proc.currentDirectoryURL = FV.home
        var env = ProcessInfo.processInfo.environment
        // Aimed at this instance, over loopback: the script resolves terminals and reads /state
        // exactly as it would typed at this Mac.
        env["FLEETVIEW_URL"] = "http://127.0.0.1:\(port)"
        env["FV_PM_SERVED"] = "1"
        env["FV_PM_COLOR"] = color ? "1" : "0"
        if let origin, !origin.isEmpty { env["FV_PM_ORIGIN"] = origin }
        // FleetView's own environment is nobody's card; a leftover id would make "your project"
        // mean whichever terminal last exported it.
        env["FLEETVIEW_TERM_ID"] = nil
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTHONIOENCODING"] = "utf-8"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        proc.environment = env

        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch {
            return ("500 Internal Server Error",
                    Result(code: 1, stdout: "", stderr: "could not start \(python): \(error.localizedDescription)\n"))
        }
        // Both pipes drained concurrently: a command that fills one while we block on the other
        // would never exit.
        let collected = Collected()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.set(data, isOut: isOut)
                group.leave()
            }
        }
        let deadline = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        group.wait()
        proc.waitUntilExit()
        deadline.cancel()

        var stdout = collected.out
        var stderr = String(decoding: collected.err, as: UTF8.self)
        if stdout.count > maxOutput {
            stdout = stdout.prefix(maxOutput)
            stderr += "… output cut at \(maxOutput >> 20) MB\n"
        }
        if proc.terminationReason == .uncaughtSignal {
            stderr += "… stopped after \(Int(timeout))s\n"
        }
        return ("200 OK", Result(code: proc.terminationStatus,
                                 stdout: String(decoding: stdout, as: UTF8.self), stderr: stderr))
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var out = Data()
        private(set) var err = Data()
        func set(_ d: Data, isOut: Bool) {
            lock.lock(); defer { lock.unlock() }
            if isOut { out = d } else { err = d }
        }
    }
}
