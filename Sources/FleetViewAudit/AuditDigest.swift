import CryptoKit
import Foundation

/// Content digests.
///
/// The log records a hash of things whose body lives elsewhere — a prompt (in the transcript), a
/// panel version (in the archive), text typed from a phone. The hash is what lets you later prove
/// "this log line refers to that content" without the log ever holding the content itself.
public enum AuditDigest {
    public static func sha256(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// First 16 hex characters — 64 bits, plenty to correlate two log lines, short enough to keep a
    /// record inside the single-line size budget.
    public static func short(_ content: String) -> String {
        String(sha256(content).prefix(16))
    }
}
