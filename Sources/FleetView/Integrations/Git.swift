import Foundation

/// Thin wrapper over the `gh` CLI for cloning. Runs through a login shell so gh/git and the
/// user's auth resolve.
enum Git {
    enum GitError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
    }

    /// Everything knowable before the clone starts, checked while the sheet is still on screen so
    /// the answer lands in the sheet — a clone now runs in the background, and "that folder already
    /// exists" arriving in a job row after the dialog closed is an answer to a question the user
    /// has stopped asking. Returns the destination directory.
    @discardableResult
    static func precheck(repo: String, into parentDir: String) throws -> String {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.failed("Enter a repository (owner/repo or URL).") }
        let dest = (parentDir as NSString).appendingPathComponent(repoName(from: trimmed))
        if FileManager.default.fileExists(atPath: dest) {
            throw GitError.failed("Destination already exists:\n\(dest)")
        }
        return dest
    }

    /// Clone `repo` (owner/repo or URL) into `parentDir`, reporting git's own progress as it goes.
    /// Returns the cloned directory path. `progress` is called from the reader thread.
    ///
    /// Cancelling the surrounding `Task` kills the clone **and removes the half-written directory**.
    /// That second half is what keeps a cancelled clone retryable: git creates the destination
    /// before it fetches a single object and `gh` refuses a destination that exists, so a cancel
    /// that left the debris behind would poison every later attempt at the same repo.
    static func clone(repo: String, into parentDir: String,
                      progress: @escaping @Sendable (Double?, String) -> Void) async throws -> String {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let dest = try precheck(repo: trimmed, into: parentDir)
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let runner = ProcessRun()
        let throttle = ProgressThrottle()
        let code: Int32
        do {
            code = try await runner.run(
                // Args are positional params ($1/$2) — no shell injection. `exec` so the shell
                // *becomes* gh: one less process between a cancel and the thing that has to die.
                // `--progress` because git only volunteers progress to a terminal, and this is a pipe.
                script: #"exec gh repo clone "$1" "$2" -- --progress"#,
                args: [trimmed, dest]
            ) { line in
                let fraction = phaseFraction(of: line)
                guard throttle.allows(fraction) else { return }
                progress(fraction, line)
            }
        } catch {
            discard(dest)
            throw error
        }
        if Task.isCancelled { discard(dest); throw CancellationError() }
        guard code == 0 else {
            discard(dest)
            let out = runner.lastLines
            FV.log("clone failed (\(code)): \(trimmed) — \(out)")
            throw GitError.failed(out.isEmpty ? "gh exited with code \(code)" : out)
        }
        return dest
    }

    /// Extract the destination folder name from owner/repo or a git URL.
    static func repoName(from repo: String) -> String {
        var s = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        s = s.replacingOccurrences(of: " ", with: "")
        return s.isEmpty ? "repo" : s
    }

    /// git reports a percentage per phase, and only three of those phases take real time. The rest
    /// — enumerating, counting, compressing — happen on GitHub's side and are over in a blink on
    /// anything you would clone from a dialog, so they get the caption but no share of the bar: a
    /// bar that runs to 100% four times reads as broken rather than as thorough.
    static func phaseFraction(of line: String) -> Double? {
        var s = line
        // "remote: Counting objects: 100% (…)" — the remote prefix would otherwise be read as the
        // phase name and every server-side line would parse as one unknown phase.
        if let r = s.range(of: "remote: ") { s = String(s[r.upperBound...]) }
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let phase = String(s[..<colon])
        let rest = s[s.index(after: colon)...]
        guard let percent = rest.firstIndex(of: "%"),
              let p = Double(rest[..<percent].filter(\.isNumber)) else { return nil }
        switch phase {
        case "Receiving objects": return 0.02 + 0.86 * (p / 100)
        case "Resolving deltas":  return 0.88 + 0.09 * (p / 100)
        case "Updating files":    return 0.97 + 0.03 * (p / 100)
        default: return nil
        }
    }

    /// A clone that did not finish leaves a directory behind, and `gh` refuses to clone into one
    /// that exists — so leaving it turns one failure into a repo that can never be cloned again
    /// from this dialog. Only ever reached for a path `precheck` established did not exist.
    private static func discard(_ dest: String) {
        try? FileManager.default.removeItem(atPath: dest)
    }

    /// SIGTERM a process and everything under it, deepest first. gh spawns git, which spawns
    /// git-remote-https; killing only the shell would leave the clone running, the destination
    /// still growing, and `discard` deleting a directory out from under a live writer.
    fileprivate static func killTree(_ pid: pid_t) {
        for child in children(of: pid) { killTree(child) }
        kill(pid, SIGTERM)
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        // Read before waiting: pgrep's output is a handful of bytes, but the order that deadlocks
        // on a full pipe is the same order regardless of how much is coming.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// A subprocess whose output is read as it arrives and which can be killed from another task.
///
/// The clone used to redirect into a log file, which is one way to avoid the classic deadlock — a
/// pipe filling up while the parent waits for exit. Draining the pipe as it fills is the other, and
/// it is the only one that can show progress: `readabilityHandler` empties the buffer continuously,
/// so it never reaches the wall the redirect was avoiding. What is left is a shutdown ordering
/// problem, which the termination handler deals with.
private final class ProcessRun: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var tail: [String] = []

    /// The last few lines, kept for a failure message: git's actual complaint is always at the end,
    /// and the whole transcript of a clone is not something to put in a popover.
    var lastLines: String {
        lock.withLock { tail.joined(separator: "\n") }
    }

    func run(script: String, args: [String],
             onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: FV.userShell)
                p.arguments = ["-l", "-c", script, "fleetview"] + args
                let pipe = Pipe()
                // Merged deliberately: git writes progress to stderr and gh writes the rest to
                // stdout, and a failure is far easier to read with both in the order they happened.
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice

                let lines = LineSplitter { [weak self] line in
                    self?.remember(line)
                    onLine(line)
                }
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                    lines.feed(data)
                }
                p.terminationHandler = { proc in
                    let handle = pipe.fileHandleForReading
                    handle.readabilityHandler = nil
                    // Whatever was written just before the exit can still be sitting in the pipe
                    // when this fires, and that tail is precisely the part worth keeping: git says
                    // *why* it gave up on its very last line, and clearing the handler without
                    // draining would throw away the only sentence the failed job could have shown.
                    if let rest = try? handle.readToEnd(), !rest.isEmpty { lines.feed(rest) }
                    lines.flush()
                    cont.resume(returning: proc.terminationStatus)
                }
                do {
                    try lock.withLock {
                        // Cancelled between being handed the task and launching it — starting now
                        // would spawn a clone with nothing left holding its handle.
                        if stopped { throw CancellationError() }
                        try p.run()
                        process = p
                    }
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let running: Process? = lock.withLock {
            stopped = true
            return process
        }
        guard let running, running.isRunning else { return }
        Git.killTree(running.processIdentifier)
    }

    private func remember(_ line: String) {
        lock.withLock {
            tail.append(line)
            if tail.count > 12 { tail.removeFirst(tail.count - 12) }
        }
    }
}

/// Turns a byte stream into lines, from whichever thread happens to be holding it.
///
/// Two of them can be: the readability handler on its own queue, and the termination handler
/// draining the tail. They are not ordered with respect to each other, so the partial line between
/// reads lives behind a lock rather than in a captured `var`.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var carry = ""
    private let emit: (String) -> Void

    init(emit: @escaping (String) -> Void) { self.emit = emit }

    func feed(_ data: Data) {
        let ready: [String] = lock.withLock {
            carry += String(decoding: data, as: UTF8.self)
            // Split on \r as well as \n: git redraws its progress line in place, so the whole
            // clone would otherwise arrive as one line that only ends when it is over.
            let parts = carry.split(omittingEmptySubsequences: false,
                                    whereSeparator: { $0 == "\n" || $0 == "\r" })
            carry = String(parts.last ?? "")
            return parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
        }
        for line in ready where !line.isEmpty { emit(line) }
    }

    /// The last line, which has no terminator behind it because the stream ended instead.
    func flush() {
        let last: String = lock.withLock {
            defer { carry = "" }
            return carry.trimmingCharacters(in: .whitespaces)
        }
        if !last.isEmpty { emit(last) }
    }
}

/// git redraws its progress line many times a second, and every one of those would be a published
/// change on the main actor. A percentage point — or a quarter second, so the byte counter still
/// moves while the percentage sits still — is as often as a progress bar can be read anyway.
private final class ProgressThrottle: @unchecked Sendable {
    private var lastPercent = Int.min
    private var lastAt = Date.distantPast

    func allows(_ fraction: Double?) -> Bool {
        let percent = fraction.map { Int($0 * 100) } ?? Int.min + 1
        let now = Date()
        guard percent != lastPercent || now.timeIntervalSince(lastAt) > 0.25 else { return false }
        lastPercent = percent
        lastAt = now
        return true
    }
}
