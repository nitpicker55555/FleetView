import Foundation

/// Thin wrapper over the `gh` CLI for cloning. Runs through a login shell so gh/git and the
/// user's auth resolve; output is redirected to a log file to avoid pipe-buffer deadlocks.
enum Git {
    enum GitError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
    }

    /// Clone `repo` (owner/repo or URL) into `parentDir`. Returns the cloned directory path.
    static func clone(repo: String, into parentDir: String) async throws -> String {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.failed("Enter a repository (owner/repo or URL).") }

        let dest = (parentDir as NSString).appendingPathComponent(repoName(from: trimmed))
        if FileManager.default.fileExists(atPath: dest) {
            throw GitError.failed("Destination already exists:\n\(dest)")
        }
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        FV.ensureSupportDir()
        let logURL = FV.supportDir.appendingPathComponent("clone-\(UUID().uuidString).log")
        // Args are passed as positional params ($1/$2/$3) — no shell injection.
        let code = try await runLoginShell(
            script: #"gh repo clone "$1" "$2" > "$3" 2>&1"#,
            args: [trimmed, dest, logURL.path])
        let out = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: logURL)

        if code != 0 {
            throw GitError.failed(out.isEmpty ? "gh exited with code \(code)" : out.trimmingCharacters(in: .whitespacesAndNewlines))
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

    private static func runLoginShell(script: String, args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: FV.userShell)
            p.arguments = ["-l", "-c", script, "fleetview"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
