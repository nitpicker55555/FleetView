import CryptoKit
import Foundation

/// Who wrote a panel version, and how confidently we know.
public struct PanelAttribution: Equatable, Sendable {
    public enum Method: String, Sendable {
        case declared               // the agent announced it itself
        case hookToolMatch = "hook_tool_match"          // a PreToolUse hook named the panel file
        case inferredSingleActive = "inferred_single_active"
        case ambiguous
        case unknown
    }

    public var method: Method
    public var terminalID: String?
    public var terminalName: String?
    public var agentKind: String?
    public var sessionID: String?
    public var transcriptPath: String?
    public var tool: String?
    public var candidates: [String]

    public init(method: Method,
                terminalID: String? = nil,
                terminalName: String? = nil,
                agentKind: String? = nil,
                sessionID: String? = nil,
                transcriptPath: String? = nil,
                tool: String? = nil,
                candidates: [String] = []) {
        self.method = method
        self.terminalID = terminalID
        self.terminalName = terminalName
        self.agentKind = agentKind
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.tool = tool
        self.candidates = candidates
    }

    public static let unknown = PanelAttribution(method: .unknown)

    public var fields: [String: AuditValue] {
        var out = AuditValue.compact([
            "attribution.method": .string(method.rawValue),
            "attribution.tool": tool.map { .string($0) },
            "agent.kind": agentKind.map { .string($0) },
            "agent.session.id": sessionID.map { .string($0) },
            "transcript.path": transcriptPath.map { .string($0) },
        ])
        if !candidates.isEmpty {
            out["attribution.candidates"] = .array(candidates.map { .string($0) })
        }
        return out
    }
}

/// A terminal that was doing something at (or near) the moment a panel appeared.
///
/// Both attribution inputs use this shape: a hook that literally named `panel.html`, and a terminal
/// that merely happened to be working.
public struct PanelWriteSignal: Equatable, Sendable {
    public let terminalID: String
    public let terminalName: String?
    public let agentKind: String?
    public let sessionID: String?
    public let transcriptPath: String?
    public let tool: String?
    public let at: Date

    public init(terminalID: String,
                terminalName: String? = nil,
                agentKind: String? = nil,
                sessionID: String? = nil,
                transcriptPath: String? = nil,
                tool: String? = nil,
                at: Date) {
        self.terminalID = terminalID
        self.terminalName = terminalName
        self.agentKind = agentKind
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.tool = tool
        self.at = at
    }
}

public enum PanelAttributionResolver {
    /// Three tiers, best first, all of them free: the hook pipeline already carries the tool name
    /// and its input, and every terminal already reports its session and transcript.
    public static func resolve(signals: [PanelWriteSignal],
                               active: [PanelWriteSignal],
                               at moment: Date,
                               window: TimeInterval = 30) -> PanelAttribution {
        // 1. Someone's tool call literally named the panel file.
        let recent = signals
            .filter { abs(moment.timeIntervalSince($0.at)) <= window }
            .max { $0.at < $1.at }
        if let hit = recent {
            return PanelAttribution(method: .hookToolMatch,
                                    terminalID: hit.terminalID, terminalName: hit.terminalName,
                                    agentKind: hit.agentKind, sessionID: hit.sessionID,
                                    transcriptPath: hit.transcriptPath, tool: hit.tool)
        }

        // 2. Exactly one terminal was working — it is the only thing that could have written it.
        let working = active.filter { abs(moment.timeIntervalSince($0.at)) <= window }
        if working.count == 1, let only = working.first {
            return PanelAttribution(method: .inferredSingleActive,
                                    terminalID: only.terminalID, terminalName: only.terminalName,
                                    agentKind: only.agentKind, sessionID: only.sessionID,
                                    transcriptPath: only.transcriptPath)
        }

        // 3. Several could have. Record them all rather than guessing.
        if working.count > 1 {
            return PanelAttribution(method: .ambiguous,
                                    candidates: working.map { $0.terminalName ?? $0.terminalID }.sorted())
        }
        return .unknown
    }
}

/// Recognises a tool call that writes the dynamic panel.
///
/// The hook script forwards Claude's raw payload verbatim, so `tool_name` and `tool_input` are
/// already flowing through the event pipeline — this just reads what was always there.
public enum PanelToolMatcher {
    public static func isPanelWrite(tool: String?, input: [String: Any]?, panelPath: String) -> Bool {
        guard let tool else { return false }
        let needle = panelPath.hasPrefix("~") ? String(panelPath.dropFirst(1)) : panelPath
        let tail = "ui/panel.html"

        func mentions(_ s: String) -> Bool { s.contains(needle) || s.contains(tail) }

        switch tool {
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            return (input?["file_path"] as? String).map(mentions) ?? false
        case "Bash", "BashOutput":
            return (input?["command"] as? String).map(mentions) ?? false
        default:
            // Unknown tools: fall back to scanning any string argument, so a new file-writing tool
            // does not silently break attribution.
            return input?.values.contains { ($0 as? String).map(mentions) ?? false } ?? false
        }
    }
}

/// One archived panel version.
public struct PanelVersion: Equatable, Sendable {
    public let uuid: String
    public let sha256: String
    public let bytes: Int
    public let title: String?
    public let previous: String?
    public let derivedFrom: String?
    public let attribution: PanelAttribution
    public let timestamp: Date

    public init(uuid: String, sha256: String, bytes: Int, title: String?, previous: String?,
                derivedFrom: String? = nil, attribution: PanelAttribution, timestamp: Date) {
        self.uuid = uuid
        self.sha256 = sha256
        self.bytes = bytes
        self.title = title
        self.previous = previous
        self.derivedFrom = derivedFrom
        self.attribution = attribution
        self.timestamp = timestamp
    }

    public var fileName: String { "\(uuid).html" }

    /// The line appended to `versions/index.jsonl`. The audit log stays authoritative; this index
    /// exists so the archive directory is self-describing and the UI can list versions instantly.
    public func indexLine(formatter: TimestampFormatter) -> String {
        var pairs: [(String, AuditValue)] = [
            ("uuid", .string(uuid)),
            ("ts", .string(formatter.string(from: timestamp))),
            ("sha256", .string(sha256)),
            ("bytes", .int(bytes)),
        ]
        if let title { pairs.append(("title", .string(title))) }
        if let previous { pairs.append(("prev", .string(previous))) }
        if let derivedFrom { pairs.append(("derived_from", .string(derivedFrom))) }
        if let id = attribution.terminalID { pairs.append(("terminal.id", .string(id))) }
        if let name = attribution.terminalName { pairs.append(("terminal.name", .string(name))) }
        if let kind = attribution.agentKind { pairs.append(("agent.kind", .string(kind))) }
        if let session = attribution.sessionID { pairs.append(("agent.session_id", .string(session))) }
        if let transcript = attribution.transcriptPath { pairs.append(("transcript", .string(transcript))) }
        pairs.append(("attribution", .string(attribution.method.rawValue)))
        return AuditEnvelope.encode(pairs)
    }

    public var auditData: [String: AuditValue] {
        var out: [String: AuditValue] = [
            "panel.uuid": .string(uuid),
            "panel.sha256": .string(sha256),
            "panel.bytes": .int(bytes),
        ]
        if let title { out["panel.title"] = .string(title) }
        if let previous { out["panel.prev_uuid"] = .string(previous) }
        if let derivedFrom { out["panel.derived_from"] = .string(derivedFrom) }
        for (k, v) in attribution.fields { out[k] = v }
        return out
    }
}

public enum PanelCapture {
    public enum Decision: Equatable {
        case capture
        case unchanged
        case invalid(reason: String)
    }

    /// Whether this content is worth archiving as a new version.
    ///
    /// Two guards matter. The skill tells agents to write the panel with `cat > panel.html`, which
    /// is **not atomic**, so a half-written file is a real possibility and must not be archived as a
    /// version. And it explicitly encourages rewriting the whole file for small updates, so
    /// identical content arrives constantly — without the digest check the archive would fill with
    /// duplicates, which is exactly the duplication the spec forbids.
    public static func decide(content: String, currentSHA: String?) -> Decision {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .invalid(reason: "empty") }
        let digest = sha256(content)
        if digest == currentSHA { return .unchanged }
        // A truncated write usually shows up as an unterminated document. Only a hint, not a
        // verdict: fragments are legitimate panels too, so this is reported, never rejected.
        return .capture
    }

    /// True when the document looks complete. Used to annotate a capture, not to block it.
    public static func looksComplete(_ content: String) -> Bool {
        let lower = content.lowercased()
        guard lower.contains("<html") || lower.contains("<body") || lower.contains("<!doctype") else {
            return true      // a bare fragment has nothing to be truncated from
        }
        return lower.contains("</html>") || lower.contains("</body>")
    }

    /// A readable name for the version list: the document title, else its first heading.
    public static func title(fromHTML html: String) -> String? {
        if let title = firstMatch(in: html, pattern: "<title[^>]*>(.*?)</title>") { return title }
        if let heading = firstMatch(in: html, pattern: "<h1[^>]*>(.*?)</h1>") { return heading }
        return nil
    }

    public static func sha256(_ content: String) -> String { AuditDigest.sha256(content) }

    private static func firstMatch(in html: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let text = html[range]
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(120))
    }
}
