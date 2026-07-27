import Foundation

/// Strips credentials out of text before it reaches the log.
///
/// Shell command lines are the dangerous surface: `export ANTHROPIC_API_KEY=…`,
/// `curl -H "Authorization: Bearer …"`, `mysql -u root:hunter2`. An audit log that records those
/// verbatim is a credential store with a friendly filename, so redaction runs before anything is
/// written and the result is flagged, letting a reader tell "there was no secret" apart from
/// "the secret was removed".
public struct Redaction: Sendable {
    public struct Rule: Sendable {
        public let regex: NSRegularExpression
        public let template: String

        public init?(_ pattern: String, template: String) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            self.regex = re
            self.template = template
        }
    }

    public static let mask = "***"

    public var rules: [Rule]

    public init(rules: [Rule]) {
        self.rules = rules
    }

    public init(patterns: [String] = Redaction.defaultPatterns) {
        self.rules = patterns.compactMap { Rule($0, template: "$1\(Redaction.mask)") }
    }

    /// `$1` keeps the identifying prefix (so you can still see *which* key was set) and the value
    /// is replaced. Ordering matters: the more specific token shapes run before the generic
    /// `NAME=value` rule.
    public static let defaultPatterns: [String] = [
        // Well-known token shapes, redacted wherever they appear.
        #"\b(gh[pousr]_|github_pat_)[A-Za-z0-9_]{8,}"#,
        #"\b(sk-[A-Za-z0-9-]{0,20})[A-Za-z0-9]{16,}"#,
        #"\b(xox[baprs]-)[A-Za-z0-9-]{8,}"#,
        // Authorization headers and basic-auth credentials.
        #"((?:Authorization|X-Api-Key)\s*:\s*(?:Bearer\s+|Basic\s+)?)[^\s"']+"#,
        #"(\s-u\s+[^\s:]+:)[^\s]+"#,
        // --password foo / --token=foo / -p foo
        #"(--?(?:password|passwd|token|secret|api[_-]?key|auth|credential)[=\s]+)[^\s]+"#,
        // NAME=value where the name looks like a credential. The prefix is optional on purpose —
        // a bare `TOKEN=…` is every bit as sensitive as `ANTHROPIC_API_KEY=…`.
        #"(\b[A-Za-z0-9_]*(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?|PRIVATE[_-]?KEY)[A-Za-z0-9_]*\s*=\s*)[^\s]+"#,
    ]

    /// Returns the redacted text and whether anything was replaced.
    public func apply(to text: String) -> (text: String, redacted: Bool) {
        var out = text
        for rule in rules {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            let replaced = rule.regex.stringByReplacingMatches(in: out, options: [], range: range,
                                                               withTemplate: rule.template)
            out = replaced
        }
        return (out, out != text)
    }
}
