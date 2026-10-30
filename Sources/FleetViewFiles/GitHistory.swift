import Foundation

/// A commit as the 提交 page lists it.
public struct GitCommit: Equatable, Sendable {
    public let sha: String
    public let parents: [String]
    public let author: String
    public let date: Date
    /// When it was committed, which is not `date` (when it was written) for a commit amended, rebased
    /// or cherry-picked since. What ties a commit to the agent call that made it (CommitLedger).
    public let committed: Date
    /// Decorations: `HEAD -> main`, `origin/main`, `tag: v0.4.0`.
    public let refs: [String]
    public let subject: String
    public let coAuthors: [String]
    /// From `--shortstat`; nil for a merge (log does not diff those) or when the counts timed out.
    public let files: Int?
    public let added: Int?
    public let deleted: Int?

    public init(sha: String, parents: [String] = [], author: String, date: Date, committed: Date,
                refs: [String] = [], subject: String, coAuthors: [String] = [],
                files: Int? = nil, added: Int? = nil, deleted: Int? = nil) {
        self.sha = sha; self.parents = parents; self.author = author; self.date = date
        self.committed = committed; self.refs = refs; self.subject = subject; self.coAuthors = coAuthors
        self.files = files; self.added = added; self.deleted = deleted
    }

    public var short: String { String(sha.prefix(7)) }

    /// "claude" or "codex" when a Co-Authored-By trailer names one of them.
    public var agent: String? {
        for c in coAuthors {
            let l = c.lowercased()
            if l.contains("claude") || l.contains("anthropic") { return "claude" }
            if l.contains("codex") || l.contains("openai") { return "codex" }
        }
        return nil
    }
}

/// `git log` in the one format the page reads.
public enum GitLog {
    /// Each record starts with \x1e; fields are NUL-separated; trailers \x01-separated; a
    /// `--shortstat` line may follow the record's header line.
    public static let format = "%x1e%H%x00%P%x00%an%x00%at%x00%ct%x00%D%x00%s%x00%(trailers:key=Co-Authored-By,valueonly=true,separator=%x01)"

    public static func parse(_ data: Data) -> [GitCommit] {
        var out: [GitCommit] = []
        for rec in data.split(separator: 0x1e) {
            let text = String(decoding: rec, as: UTF8.self)
            let fields = text.split(separator: "\0", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 8, fields[0].count >= 7 else { continue }
            // The last field is the trailers, then — after a newline — the shortstat, if any.
            let tail = fields[7]
            let nl = tail.firstIndex(of: "\n")
            let trailers = nl.map { String(tail[..<$0]) } ?? tail
            let stat = nl.map { String(tail[$0...]) } ?? ""
            let (files, added, deleted) = shortstat(stat)
            out.append(GitCommit(
                sha: fields[0],
                parents: fields[1].split(separator: " ").map(String.init),
                author: fields[2],
                date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0),
                committed: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                refs: fields[5].isEmpty ? [] : fields[5].components(separatedBy: ", "),
                subject: fields[6],
                coAuthors: trailers.split(separator: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                files: files, added: added, deleted: deleted))
        }
        return out
    }

    /// " 3 files changed, 10 insertions(+), 2 deletions(-)" — any part may be missing.
    static func shortstat(_ s: String) -> (Int?, Int?, Int?) {
        guard s.contains("changed") else { return (nil, nil, nil) }
        var files: Int?, added = 0, deleted = 0
        for part in s.split(separator: ",") {
            let words = part.split(whereSeparator: { $0 == " " || $0 == "\n" })
            guard let n = words.first.flatMap({ Int($0) }) else { continue }
            if part.contains("file") { files = n }
            else if part.contains("insertion") { added = n }
            else if part.contains("deletion") { deleted = n }
        }
        return (files, added, deleted)
    }
}

/// A branch, local or remote.
public struct GitBranch: Equatable, Sendable {
    /// `main`, `origin/main`.
    public let name: String
    public let sha: String
    public let date: Date
    public let isHead: Bool
    public let isRemote: Bool
}

public enum GitBranches {
    public static let format = "%(refname)%00%(objectname)%00%(committerdate:unix)%00%(HEAD)"

    public static func parse(_ data: Data) -> [GitBranch] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4 else { return nil }
            let ref = f[0]
            let remote = ref.hasPrefix("refs/remotes/")
            let name = remote ? String(ref.dropFirst("refs/remotes/".count)) : String(ref.dropFirst("refs/heads/".count))
            // `origin/HEAD` is a pointer to another remote branch, not a branch.
            if remote && name.hasSuffix("/HEAD") { return nil }
            return GitBranch(name: name, sha: f[1], date: Date(timeIntervalSince1970: TimeInterval(f[2]) ?? 0),
                             isHead: f[3] == "*", isRemote: remote)
        }
    }
}

/// One file in a set of changes.
public struct GitChange: Equatable, Sendable {
    /// Repository-relative, after the change.
    public let path: String
    /// Before the change, for a rename or copy.
    public let oldPath: String?
    /// A, M, D, R, C, T (type change), U (unmerged); "?" for an untracked file.
    public let status: String
    public let added: Int?
    public let deleted: Int?
    public let binary: Bool

    public init(path: String, oldPath: String?, status: String, added: Int?, deleted: Int?, binary: Bool) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.added = added
        self.deleted = deleted
        self.binary = binary
    }
}

public enum GitChanges {
    /// `--name-status -z` and `--numstat -z` of the same diff, joined by path.
    ///
    /// `onlyCounted`: drop modifications `--numstat` does not list. `diff-index` compares with the
    /// index's stat data without refreshing it, so a file that was only touched is "M" by name and
    /// absent from the counts — it did not change.
    public static func parse(nameStatus: Data, numstat: Data, onlyCounted: Bool = false) -> [GitChange] {
        // numstat -z: "add\tdel\tpath\0", or for a rename "add\tdel\t\0old\0new\0"; "-\t-" for binary.
        var counts: [String: (Int?, Int?, Bool)] = [:]
        let n = GitReader.splitNULKeepingEmpty(numstat)
        var i = 0
        while i < n.count {
            let rec = n[i]; i += 1
            let parts = rec.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let binary = parts[0] == "-"
            let a = Int(parts[0]), d = Int(parts[1])
            var path = String(parts[2])
            if path.isEmpty, i + 1 < n.count { path = n[i + 1]; i += 2 }     // old, new
            counts[path] = (a, d, binary)
        }
        // name-status -z: "M\0path\0", "R100\0old\0new\0".
        var out: [GitChange] = []
        let s = GitReader.splitNULKeepingEmpty(nameStatus)
        i = 0
        while i < s.count {
            let code = s[i]; i += 1
            guard let letter = code.first, i < s.count else { continue }
            var old: String? = nil
            var path = s[i]; i += 1
            if letter == "R" || letter == "C", i < s.count { old = path; path = s[i]; i += 1 }
            let c = counts[path]
            if onlyCounted && letter == "M" && c == nil { continue }
            out.append(GitChange(path: path, oldPath: old, status: String(letter),
                                 added: c?.0, deleted: c?.1, binary: c?.2 ?? false))
        }
        return out
    }
}

/// Which two versions a set of changes is between.
public enum GitRange: Equatable, Sendable {
    /// A commit against its first parent (or against nothing, for a root commit).
    case commit(String)
    /// One version against another.
    case between(String, String)
    /// A version against the working tree.
    case worktree(String)
}

extension GitReader {
    /// Commits, newest first. `ref` nil is HEAD; `path` (repository-relative) limits to commits that
    /// changed it — followed across renames when it is one file. nil when git failed (no commits yet,
    /// say).
    public func log(_ repo: Repo, ref: String? = nil, path: String? = nil, follow: Bool = false,
                    skip: Int = 0, limit: Int = 100, cancel: CancelToken? = nil) -> [GitCommit]? {
        func args(stats: Bool) -> [String] {
            var a = ["log", "--no-color", "-n", String(limit), "--format=" + GitLog.format]
            if stats { a.append("--shortstat") }
            if skip > 0 { a.append("--skip=\(skip)") }
            if follow && path != nil { a.append("--follow") }
            a.append(ref ?? "HEAD")
            a.append("--")
            if let path, !path.isEmpty { a.append(path) }
            return a
        }
        // Counting lines means diffing every commit listed: bounded, and dropped when it runs over.
        var r = run(args(stats: true), in: repo.toplevel, timeout: 8, limit: 16 << 20, cancel: cancel)
        if r.status != 0 && cancel?.isCancelled != true {
            r = run(args(stats: false), in: repo.toplevel, timeout: 10, limit: 16 << 20, cancel: cancel)
        }
        guard r.status == 0 else { return nil }
        return GitLog.parse(r.out)
    }

    /// The working trees of a repository, its own first: they share its commits, so a commit made in
    /// any of them is one of its commits. `worktree list` only reads.
    public func worktrees(_ repo: Repo) -> [String] {
        let r = run(["worktree", "list", "--porcelain"], in: repo.toplevel, timeout: 5)
        guard r.status == 0 else { return [repo.toplevel] }
        let list = String(decoding: r.out, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst("worktree ".count)) }
        return list.isEmpty ? [repo.toplevel] : list
    }

    /// Every commit on any ref committed between two moments, newest first, without counts — what
    /// the agents' calls are matched against, so it is asked for one call's span at a time.
    public func commits(_ repo: Repo, from: Date, to: Date, limit: Int = 200) -> [GitCommit] {
        let r = run(["log", "--no-color", "--all", "-n", String(limit), "--format=" + GitLog.format,
                     "--since=@\(Int(from.timeIntervalSince1970))", "--until=@\(Int(to.timeIntervalSince1970.rounded(.up)))", "--"],
                    in: repo.toplevel, timeout: 10, limit: 4 << 20)
        return r.status == 0 ? GitLog.parse(r.out) : []
    }

    /// Local and remote branches, most recently committed to first.
    public func branches(_ repo: Repo) -> [GitBranch] {
        let r = run(["for-each-ref", "--sort=-committerdate", "--format=" + GitBranches.format, "refs/heads", "refs/remotes"],
                    in: repo.toplevel)
        return r.status == 0 ? GitBranches.parse(r.out) : []
    }

    public func mergeBase(_ repo: Repo, _ a: String, _ b: String) -> String? {
        let r = run(["merge-base", a, b], in: repo.toplevel)
        guard r.status == 0 else { return nil }
        let s = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private func diffArgs(_ range: GitRange, _ mode: [String]) -> [String] {
        switch range {
        case .commit(let sha):
            return ["diff-tree", "-r", "-z", "-M", "--root", "-m", "--first-parent", "--no-commit-id"] + mode + [sha]
        case .between(let a, let b):
            return ["diff-tree", "-r", "-z", "-M"] + mode + [a, b]
        case .worktree(let a):
            return ["diff-index", "-z", "-M"] + mode + [a]
        }
    }

    /// The files that differ, repository-relative. `under` limits to a folder. Untracked files are
    /// not here — the caller adds them for a working-tree range.
    public func changes(_ repo: Repo, _ range: GitRange, under: String? = nil) -> [GitChange]? {
        var spec = ["--"]
        if let under, !under.isEmpty { spec.append(under) }
        let names = run(diffArgs(range, ["--name-status"]) + spec, in: repo.toplevel, timeout: 15, limit: 16 << 20)
        guard names.status == 0 else { return nil }
        let nums = run(diffArgs(range, ["--numstat"]) + spec, in: repo.toplevel, timeout: 15, limit: 16 << 20)
        if case .worktree = range {
            return GitChanges.parse(nameStatus: names.out, numstat: nums.out, onlyCounted: true)
        }
        return GitChanges.parse(nameStatus: names.out, numstat: nums.out)
    }

    /// The unified diff of the given files (both names of a rename), at most `limit` bytes.
    public func patch(_ repo: Repo, _ range: GitRange, paths: [String], limit: Int = 4 << 20) -> (text: Data, truncated: Bool)? {
        var args: [String]
        switch range {
        case .commit(let sha):
            args = ["diff-tree", "-p", "-M", "--no-color", "--root", "-m", "--first-parent", "--no-commit-id", sha]
        case .between(let a, let b):
            args = ["diff-tree", "-p", "-M", "--no-color", a, b]
        case .worktree(let a):
            args = ["diff-index", "-p", "-M", "--no-color", a]
        }
        args += ["--"] + paths
        let r = run(args, in: repo.toplevel, timeout: 15, limit: limit)
        guard r.status == 0 || r.truncated else { return nil }
        return (r.out, r.truncated)
    }

    /// A file as a version has it, as it would be checked out (see `checkedOut`). `path` is
    /// repository-relative.
    public func blob(_ repo: Repo, rev: String, path: String) -> Data? {
        var r = run(["cat-file", "--filters", "\(rev):\(path)"], in: repo.toplevel, timeout: 10)
        if r.status != 0 { r = run(["cat-file", "blob", "\(rev):\(path)"], in: repo.toplevel, timeout: 10) }
        return r.status == 0 ? r.out : nil
    }

    /// The first parent of a commit, or nil for a root commit.
    public func firstParent(_ repo: Repo, of sha: String) -> String? {
        let r = run(["rev-parse", "-q", "--verify", sha + "^1"], in: repo.toplevel)
        guard r.status == 0 else { return nil }
        let s = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// One commit's details (for a tab opened from a link or a sha).
    public func commit(_ repo: Repo, _ sha: String) -> GitCommit? {
        let r = run(["log", "--no-color", "-n", "1", "--format=" + GitLog.format, "--shortstat", sha, "--"], in: repo.toplevel)
        return r.status == 0 ? GitLog.parse(r.out).first : nil
    }

    /// The commit's whole message (the list has only the subject).
    public func message(_ repo: Repo, _ sha: String) -> String? {
        let r = run(["log", "--no-color", "-n", "1", "--format=%B", sha, "--"], in: repo.toplevel)
        return r.status == 0 ? String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    static func splitNULKeepingEmpty(_ data: Data) -> [String] {
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}
