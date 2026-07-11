import Foundation

/// Watches ~/.fleetview/events for hook event files dropped by hook.sh (atomic writes),
/// parses them, and delivers extracted (Sendable) fields. A simple timer poll keeps the
/// code trivial and reliable — events are infrequent (one per prompt / turn).
final class EventWatcher {
    struct Event: Sendable {
        let event: String
        let term: String
        let sessionId: String?
        let transcriptPath: String?
        let cwd: String?
        let prompt: String?
        let message: String?
    }

    private let dir: URL
    private let queue = DispatchQueue(label: "fleetview.events")
    private var timer: DispatchSourceTimer?
    var onEvent: ((Event) -> Void)?

    init() {
        dir = FV.supportDir.appendingPathComponent("events", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.12)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func scan() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }

        let jsons = files.filter { $0.pathExtension == "json" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }

        for f in jsons {
            defer { try? fm.removeItem(at: f) }
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = obj["event"] as? String,
                  let term = obj["term"] as? String else { continue }
            let p = (obj["payload"] as? [String: Any]) ?? [:]
            let ev = Event(event: event,
                           term: term,
                           sessionId: p["session_id"] as? String,
                           transcriptPath: p["transcript_path"] as? String,
                           cwd: p["cwd"] as? String,
                           prompt: p["prompt"] as? String,
                           message: p["message"] as? String)
            onEvent?(ev)
        }
    }
}
