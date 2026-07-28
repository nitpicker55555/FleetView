import FleetViewAudit
import Foundation

/// Keeps every version of the agent-authored panel, named by UUIDv7, and records who wrote each one.
///
/// `~/.fleetview/ui/panel.html` is left exactly where it is — versions are copies. That keeps the
/// skill's contract, the agents already writing it and the `/panel` route all unchanged; archiving
/// is a pure addition.
///
/// ```
/// ~/.fleetview/ui/
/// ├── panel.html                       current, as always
/// ├── current.json                     {"uuid":…,"sha256":…}
/// └── versions/
///     ├── index.jsonl                  one line per version
///     └── 019820f1-….html              永久保留
/// ```
///
/// UUIDv7 rather than v4 because its first 48 bits are a millisecond timestamp (RFC 9562): the
/// newest version is simply the lexicographically largest filename, so `ls` alone finds it even if
/// the index is lost.
@MainActor
final class PanelVersions {
    static let shared = PanelVersions()

    private(set) var currentUUID: String?
    private(set) var currentSHA: String?
    private var previousUUID: String?

    /// (mtime, size) seen on the previous tick. A write is only archived once these stop moving.
    private var lastStat: (mtime: TimeInterval, size: Int)?
    private let formatter = TimestampFormatter()

    private init() {}

    struct Stat: Equatable {
        let mtime: TimeInterval
        let size: Int
    }

    func load() {
        guard let data = try? Data(contentsOf: FV.panelCurrent),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        currentUUID = json["uuid"] as? String
        currentSHA = json["sha256"] as? String
    }

    /// Called on every panel-watch tick. Returns a version when one was archived.
    ///
    /// `attribution` is only evaluated when a capture actually happens, so the (cheap but nonzero)
    /// work of figuring out which agent wrote it does not run once a second forever.
    @discardableResult
    func check(auditor: Auditor, attribution: () -> PanelAttribution) -> PanelVersion? {
        guard let stat = currentStat() else {
            handleDisappearance(auditor: auditor)
            return nil
        }

        // Wait for the file to stop changing. The skill teaches `cat > panel.html <<'HTML'`, which
        // is not atomic — archiving the moment mtime moves would eventually store half a document.
        let previous = lastStat
        lastStat = (stat.mtime, stat.size)
        guard let previous, previous.mtime == stat.mtime, previous.size == stat.size else { return nil }

        guard let content = try? String(contentsOf: FV.panelHTML, encoding: .utf8) else { return nil }
        switch PanelCapture.decide(content: content, currentSHA: currentSHA) {
        case .unchanged:
            return nil
        case .invalid(let reason):
            // Only report the first time, or a broken file would alert once a second.
            if currentSHA != nil {
                auditor.emit(AuditEvent(name: "fleetview.panel.capture_failed",
                                        kind: .alert, categories: ["configuration"],
                                        outcome: .failure,
                                        message: "panel not archived: \(reason)",
                                        data: ["reason": .string(reason)]))
                currentSHA = nil
            }
            return nil
        case .capture:
            return capture(content: content, auditor: auditor, attribution: attribution())
        }
    }

    /// Restore an archived version by copying it back. The copy is picked up by the normal capture
    /// path and becomes a *new* version pointing at the one it restored — history stays append-only.
    func rollback(to uuid: String) -> Bool {
        let source = FV.panelVersionsDir.appendingPathComponent("\(uuid).html")
        guard let html = try? String(contentsOf: source, encoding: .utf8) else { return false }
        previousUUID = uuid
        try? html.write(to: FV.panelHTML, atomically: true, encoding: .utf8)
        return true
    }

    func html(uuid: String) -> String? {
        // Defend the archive against a crafted `?v=../../something`.
        guard uuid.range(of: "^[0-9a-fA-F-]{36}$", options: .regularExpression) != nil else { return nil }
        return try? String(contentsOf: FV.panelVersionsDir.appendingPathComponent("\(uuid).html"),
                           encoding: .utf8)
    }

    /// Newest first, for the history picker.
    func recentVersions(limit: Int = 50) -> [String] {
        guard let text = try? String(contentsOf: FV.panelIndex, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(limit).reversed().map(String.init)
    }

    struct Summary: Identifiable, Hashable {
        let uuid: String
        let time: String
        let title: String
        let terminal: String
        var id: String { uuid }
        var label: String {
            [time, terminal, title].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    func recentSummaries(limit: Int = 30) -> [Summary] {
        recentVersions(limit: limit).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uuid = json["uuid"] as? String else { return nil }
            let stamp = (json["ts"] as? String) ?? ""
            // "2026-07-28T16:41:09.220+02:00" → "16:41"
            let time = stamp.count > 16 ? String(stamp.dropFirst(11).prefix(5)) : stamp
            return Summary(uuid: uuid,
                           time: time,
                           title: (json["title"] as? String) ?? "",
                           terminal: (json["terminal.name"] as? String) ?? "")
        }
    }

    // MARK: - Internals

    private func currentStat() -> Stat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: FV.panelHTML.path),
              let size = attrs[.size] as? Int else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Stat(mtime: mtime, size: size)
    }

    private func handleDisappearance(auditor: Auditor) {
        lastStat = nil
        guard let uuid = currentUUID else { return }
        auditor.emit(AuditEvent(name: "fleetview.panel.removed",
                                categories: ["configuration"],
                                message: "panel removed (history kept)",
                                target: AuditTarget(kind: "panel", id: uuid),
                                data: ["versions_retained": .int(countVersions())]))
        currentUUID = nil
        currentSHA = nil
        try? FileManager.default.removeItem(at: FV.panelCurrent)
    }

    private func capture(content: String, auditor: Auditor, attribution: PanelAttribution) -> PanelVersion? {
        let fm = FileManager.default
        try? fm.createDirectory(at: FV.panelVersionsDir, withIntermediateDirectories: true)
        // The very first capture usually finds a panel that was already on disk before auditing
        // existed. Nothing can be attributed to it, and saying so beats an unexplained "unknown".
        let preexisting = currentUUID == nil && currentSHA == nil

        let version = PanelVersion(uuid: Identifiers.uuidV7(),
                                   sha256: PanelCapture.sha256(content),
                                   bytes: content.utf8.count,
                                   title: PanelCapture.title(fromHTML: content),
                                   previous: currentUUID,
                                   derivedFrom: previousUUID,
                                   attribution: attribution,
                                   timestamp: Date())
        previousUUID = nil

        let destination = FV.panelVersionsDir.appendingPathComponent(version.fileName)
        guard (try? content.write(to: destination, atomically: true, encoding: .utf8)) != nil else {
            auditor.emit(AuditEvent(name: "fleetview.panel.capture_failed",
                                    kind: .alert, categories: ["configuration"], outcome: .failure,
                                    message: "could not write the version file",
                                    data: ["reason": .string("write_failed")]))
            return nil
        }
        // Snapshot the panel's data alongside it, so a historical panel can be replayed with the
        // numbers it was showing rather than with today's.
        if let data = try? Data(contentsOf: FV.panelJSON) {
            try? data.write(to: FV.panelVersionsDir.appendingPathComponent("\(version.uuid).data.json"))
        }
        appendIndex(version)

        currentUUID = version.uuid
        currentSHA = version.sha256
        writeCurrent(version)

        var data = version.auditData
        data["panel.path"] = .string(destination.path)
        if !PanelCapture.looksComplete(content) { data["panel.incomplete"] = .bool(true) }
        if preexisting { data["panel.preexisting"] = .bool(true) }

        let who = attribution.terminalName
            ?? (preexisting ? "an earlier run (archived on first sight)" : attribution.method.rawValue)
        auditor.emit(AuditEvent(name: "fleetview.panel.version_created",
                                categories: ["configuration"],
                                types: ["creation"],
                                message: "panel \(version.uuid.prefix(8)) "
                                       + "(\(version.bytes) B\(version.title.map { ", \"\($0)\"" } ?? "")) "
                                       + "written by \(who)",
                                actor: attributionActor(attribution),
                                target: AuditTarget(kind: "panel", id: version.uuid,
                                                    name: version.title,
                                                    fields: AuditValue.compact([
                                                        "terminal.id": attribution.terminalID.map { .string($0) },
                                                        "terminal.name": attribution.terminalName.map { .string($0) },
                                                    ])),
                                data: data))
        auditor.emit("fleetview.panel.activated",
                     categories: ["configuration"],
                     message: "now rendering panel \(version.uuid.prefix(8))",
                     target: AuditTarget(kind: "panel", id: version.uuid),
                     data: AuditValue.compact([
                        "mode": .string(version.derivedFrom == nil ? "latest" : "rollback"),
                        "panel.prev_uuid": version.previous.map { .string($0) },
                     ]))
        return version
    }

    /// A panel written by an agent is logged as that agent's action, not as the app's.
    private func attributionActor(_ attribution: PanelAttribution) -> AuditActor? {
        guard attribution.terminalID != nil else { return nil }
        return AuditActor(kind: .agent, id: attribution.sessionID,
                          name: attribution.terminalName, agentKind: attribution.agentKind)
    }

    private func appendIndex(_ version: PanelVersion) {
        let line = version.indexLine(formatter: formatter) + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: FV.panelIndex.path),
           let handle = try? FileHandle(forWritingTo: FV.panelIndex) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: FV.panelIndex)
        }
    }

    private func writeCurrent(_ version: PanelVersion) {
        let payload: [String: Any] = [
            "uuid": version.uuid,
            "sha256": version.sha256,
            "since": formatter.string(from: version.timestamp),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: FV.panelCurrent, options: .atomic)
    }

    private func countVersions() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: FV.panelVersionsDir.path))?
            .filter { $0.hasSuffix(".html") }.count ?? 0
    }
}
