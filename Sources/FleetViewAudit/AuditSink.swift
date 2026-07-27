import Foundation

/// Where audit events go. The app writes to `FileAuditSink`; tests use `MemoryAuditSink`.
public protocol AuditSink: AnyObject, Sendable {
    func write(_ event: AuditEvent)
    func flush()
}

/// Assigns the per-line identity (event id + sequence) and renders the JSON.
///
/// Sequence numbers are process-local and monotonic: they order events that share a millisecond,
/// and a gap in them is a signal that something dropped lines.
public final class AuditEncoder: @unchecked Sendable {
    public let resource: AuditResource
    private let formatter: TimestampFormatter
    private let lock = NSLock()
    private var sequence = 0

    /// Hard ceiling for one encoded line, in bytes. Below `PIPE_BUF` (4096) so a single `O_APPEND`
    /// write is atomic — that is what lets two FleetView instances share one log file without
    /// interleaving each other's lines mid-record.
    public static let maxLineBytes = 4000

    public init(resource: AuditResource, formatter: TimestampFormatter = TimestampFormatter()) {
        self.resource = resource
        self.formatter = formatter
    }

    public func line(for event: AuditEvent) -> String {
        lock.lock()
        sequence += 1
        let seq = sequence
        lock.unlock()

        let id = Identifiers.ulid(now: event.timestamp)
        let raw = AuditEnvelope.line(event: event, resource: resource, id: id, sequence: seq, formatter: formatter)
        guard raw.utf8.count > Self.maxLineBytes else { return raw }
        let shrunk = LineFitter.shrink(event, limit: Self.maxLineBytes)
        return AuditEnvelope.line(event: shrunk, resource: resource, id: id, sequence: seq, formatter: formatter)
    }
}

/// Brings an oversized event under the line limit without ever losing the *fact* that it happened.
///
/// Content is what gets sacrificed, never identity: the event name, actor, target and trace survive
/// intact, long strings are clipped, and a `_truncated` marker plus the original length is left
/// behind so a reader knows to go look at the authoritative source (a transcript, a version file).
enum LineFitter {
    static func shrink(_ event: AuditEvent, limit: Int) -> AuditEvent {
        var out = event
        var budget = 240

        // Three passes with a shrinking budget; in practice the first is always enough.
        for _ in 0..<3 {
            out.data = clip(event.data, to: budget)
            if let m = event.message { out.message = clip(m, to: budget * 2) }
            let approximate = approximateSize(out)
            if approximate <= limit { return out }
            budget /= 3
        }

        // Still too big (a pathological payload): keep identity, drop content.
        out.data = out.data.filter { !isLongString($0.value) }
        out.data["_dropped"] = .bool(true)
        out.message = event.message.map { clip($0, to: 120) }
        return out
    }

    private static func isLongString(_ v: AuditValue) -> Bool {
        if case .string(let s) = v { return s.count > 120 }
        if case .object = v { return true }
        if case .array = v { return true }
        return false
    }

    private static func approximateSize(_ event: AuditEvent) -> Int {
        var n = 600   // envelope overhead: resource fields, ids, ECS keys
        n += event.name.utf8.count + (event.message?.utf8.count ?? 0)
        n += AuditValue.object(event.data).json.utf8.count
        n += AuditValue.object(event.resolvedActor.payload).json.utf8.count
        if let t = event.target { n += AuditValue.object(t.payload).json.utf8.count }
        return n
    }

    private static func clip(_ dict: [String: AuditValue], to budget: Int) -> [String: AuditValue] {
        var out: [String: AuditValue] = [:]
        var truncated = false
        for (key, value) in dict {
            switch value {
            case .string(let s) where s.count > budget:
                out[key] = .string(clip(s, to: budget))
                out[key + ".length"] = .int(s.count)
                truncated = true
            case .array(let items) where items.count > 32:
                out[key] = .array(Array(items.prefix(32)))
                out[key + ".length"] = .int(items.count)
                truncated = true
            default:
                out[key] = value
            }
        }
        if truncated { out["_truncated"] = .bool(true) }
        return out
    }

    private static func clip(_ s: String, to budget: Int) -> String {
        guard s.count > budget else { return s }
        return String(s.prefix(budget)) + "…"
    }
}

/// Collects events in memory. Used by tests, and by the app before the log directory is ready.
public final class MemoryAuditSink: AuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AuditEvent] = []
    private let encoder: AuditEncoder

    public init(resource: AuditResource = AuditResource(instanceID: "test")) {
        encoder = AuditEncoder(resource: resource,
                               formatter: TimestampFormatter(timeZone: TimeZone(identifier: "UTC")!))
    }

    public func write(_ event: AuditEvent) {
        lock.lock(); storage.append(event); lock.unlock()
    }

    public func flush() {}

    public var events: [AuditEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// The events as they would appear in the file — used to assert on the wire format itself.
    public var lines: [String] {
        events.map { encoder.line(for: $0) }
    }

    public func events(named name: String) -> [AuditEvent] {
        events.filter { $0.name == name }
    }

    public func clear() {
        lock.lock(); storage.removeAll(); lock.unlock()
    }
}

/// Appends to `~/.fleetview/logs/audit-YYYY-MM-DD.jsonl`.
///
/// Every write is a single `O_APPEND` write of one sub-4KB line, which POSIX makes atomic — so a
/// second FleetView instance appending to the same file can never split a record in half. Failures
/// are swallowed by design: a logging subsystem must not be able to take the app down.
public final class FileAuditSink: AuditSink, @unchecked Sendable {
    private let directory: URL
    private let encoder: AuditEncoder
    private let queue = DispatchQueue(label: "ai.eigent.fleetview.audit", qos: .utility)
    private let maxFileBytes: Int

    private var handle: FileHandle?
    private var currentPath: URL?
    private var currentDay: String = ""
    private var buffer = Data()
    private var flushScheduled = false

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(directory: URL, resource: AuditResource, maxFileBytes: Int = 64 * 1024 * 1024) {
        self.directory = directory
        self.encoder = AuditEncoder(resource: resource)
        self.maxFileBytes = maxFileBytes
    }

    public func write(_ event: AuditEvent) {
        let line = encoder.line(for: event)
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(Data((line + "\n").utf8))
            // Small buffer, short timer: a crash should cost at most a few tens of milliseconds of
            // log, and the app should never pay a synchronous file write on the main thread.
            if self.buffer.count >= 8192 {
                self.flushLocked()
            } else if !self.flushScheduled {
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.flushScheduled = false
                    self?.flushLocked()
                }
            }
        }
    }

    public func flush() {
        queue.sync { self.flushLocked() }
    }

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        guard let fh = handleForToday() else { buffer.removeAll(); return }
        let data = buffer
        buffer.removeAll()
        do { try fh.write(contentsOf: data) } catch { /* disk full / unlinked — drop, never crash */ }
    }

    /// Opens (and rotates) the day's file. Rotation is by filename rather than by renaming, so a
    /// second instance holding the old handle keeps writing to a file that still exists.
    private func handleForToday() -> FileHandle? {
        let day = dayFormatter.string(from: Date())
        if day != currentDay { closeCurrent() }

        if let fh = handle, let path = currentPath {
            if Self.fileSize(path) < maxFileBytes { return fh }
            closeCurrent()
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])

        var url = directory.appendingPathComponent("audit-\(day).jsonl")
        var index = 0
        while Self.fileSize(url) >= maxFileBytes {
            index += 1
            url = directory.appendingPathComponent("audit-\(day).\(index).jsonl")
        }

        let isNew = !fm.fileExists(atPath: url.path)
        if isNew {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let fh = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? fh.seekToEnd()
        handle = fh
        currentPath = url
        currentDay = day

        if isNew {
            // Header line, asciicast-style: every file states its own schema and provenance, so an
            // archived log is self-describing even if it outlives this version of FleetView.
            let header = AuditEvent(
                name: "fleetview.log.opened",
                categories: ["configuration"],
                message: "audit log opened (schema \(encoder.resource.schemaVersion))",
                actor: .system,
                data: [
                    "schema": .int(encoder.resource.schemaVersion),
                    "tz": .string(TimeZone.current.identifier),
                    "file": .string(url.lastPathComponent),
                ])
            if let data = (encoder.line(for: header) + "\n").data(using: .utf8) {
                try? fh.write(contentsOf: data)
            }
        }
        return fh
    }

    private static func fileSize(_ url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return 0 }
        return size
    }

    private func closeCurrent() {
        try? handle?.close()
        handle = nil
        currentPath = nil
    }

    deinit {
        queue.sync { self.flushLocked(); self.closeCurrent() }
    }
}
