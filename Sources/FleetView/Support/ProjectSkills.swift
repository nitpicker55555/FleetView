import Foundation

/// One agent skill carried by a project: `<project>/.claude/skills/<dir>/SKILL.md`.
struct SkillInfo: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let description: String
    /// Absolute path to the SKILL.md — the thing the panel offers to copy, because that is what you
    /// paste into a prompt or an editor. The directory is one `dirname` away if you need it instead.
    let path: String
}

/// Reads the skills a project ships with.
///
/// Only the project's own `.claude/skills` is scanned. User-level skills (`~/.claude/skills`) are
/// left out deliberately: this list answers "what does *this* repo carry", and folding in skills
/// that follow the person around would make one project list differently on another machine.
enum ProjectSkills {
    static func scan(projectPath: String) -> [SkillInfo] {
        guard !projectPath.isEmpty else { return [] }
        let root = URL(fileURLWithPath: projectPath).appendingPathComponent(".claude/skills",
                                                                           isDirectory: true)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [SkillInfo] = []
        for dir in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let md = root.appendingPathComponent(dir).appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: md.path),
                  let text = try? String(contentsOf: md, encoding: .utf8) else { continue }
            let head = frontMatter(text)
            // A SKILL.md with no `name` still shows up, under its directory name — a skill that is
            // there but undeclared is exactly the case you want the list to reveal, not hide.
            out.append(SkillInfo(name: head["name"] ?? dir,
                                 description: head["description"] ?? "",
                                 path: md.path))
        }
        return out
    }

    /// The `---` fenced YAML head of a SKILL.md, flattened to the scalars this panel shows.
    ///
    /// Not a YAML parser, and not trying to be. It handles top-level `key: value` plus the block
    /// scalars (`>-`, `>`, `|`, `|-`) these files actually use for long descriptions — those put
    /// nothing after the colon and continue on the following indented lines, so a naive
    /// line-by-line read reports an empty description for most real skills.
    static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var pendingKey: String?
        var block: [String] = []

        func flush() {
            defer { pendingKey = nil; block = [] }
            guard let k = pendingKey else { return }
            let joined = block.map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { out[k] = joined }
        }

        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            // Indented means "continuation": either a block scalar's body, or the children of a
            // nested key we are not collecting — `pendingKey == nil` tells the two apart.
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if pendingKey != nil { block.append(line) }
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if ["\u{3E}-", "\u{3E}", "|", "|-"].contains(raw) { pendingKey = key; continue }
            let value = unquoted(raw)
            if !value.isEmpty { out[key] = value }
        }
        flush()
        return out
    }

    private static func unquoted(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
