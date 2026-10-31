import FleetViewAudit
import Foundation

/// The app's side of the fleet triggers (see FleetTriggerEngine): starting the engine, the HTTP API
/// `project-manager trigger` and both UIs use, and the way back to the card that set one up.
extension AppState {

    func startFleetTriggers() {
        let engine = FleetTriggerEngine.shared
        engine.auditor = audit
        engine.onChange = { [weak self] list in
            Task { @MainActor in self?.fleetTriggers = list }
        }
        engine.start()
    }

    /// `/fleet-triggers…`:
    ///
    ///     GET  /fleet-triggers                     the list
    ///     POST /fleet-triggers/add                 {name, when:{kind,…}, run, cwd?, timeout?}
    ///     POST /fleet-triggers/rm?id=              remove it (and stop a run still going)
    ///     POST /fleet-triggers/fire?id=            run it now
    ///     POST /fleet-triggers/pause?id=&on=1|0    pause / resume
    ///     GET  /fleet-triggers/log?id=&n=          the end of its log
    ///     POST /fleet-triggers/restore?id=         bring back the card that set it up
    ///
    /// `caller` is the card a `project-manager` call came from (its X-FV-Caller header). A trigger
    /// added from inside a card records that card as its source.
    func fleetTriggerResponse(path: String, method: String, query: [String: String], body: Data,
                              caller: String?) -> (status: String, body: Data) {
        let engine = FleetTriggerEngine.shared
        func json(_ status: String, _ obj: Any) -> (String, Data) {
            (status, (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8))
        }
        func bad(_ status: String, _ msg: String) -> (String, Data) { json(status, ["error": msg]) }
        let mutating = path != "/fleet-triggers" && path != "/fleet-triggers/log"
        if mutating && method != "POST" { return bad("405 Method Not Allowed", "POST only") }
        let id = query["id"] ?? ""

        switch path {
        case "/fleet-triggers":
            return json("200 OK", ["triggers": engine.list().map(fleetTriggerJSON)])

        case "/fleet-triggers/add":
            guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let whenObj = obj["when"],
                  let whenData = try? JSONSerialization.data(withJSONObject: whenObj),
                  let when = try? FleetTriggerEngine.decoder.decode(FleetTriggerWhen.self, from: whenData)
            else { return bad("400 Bad Request", "body must be JSON with when:{kind,…} and run") }
            let (source, name, transcript) = fleetTriggerSource(caller)
            let draft = FleetTrigger(id: "", name: obj["name"] as? String ?? "", when: when,
                                     run: obj["run"] as? String ?? "", cwd: obj["cwd"] as? String,
                                     timeout: obj["timeout"] as? Double, source: source,
                                     sourceName: name, sourceTranscript: transcript, createdAt: Date())
            do {
                let t = try engine.add(draft)
                return json("200 OK", fleetTriggerJSON(FleetTriggerStatus(trigger: t, running: false)))
            } catch FleetTriggerEngine.Failure.invalid(let why) {
                return bad("400 Bad Request", why)
            } catch {
                return bad("500 Internal Server Error", "\(error)")
            }

        case "/fleet-triggers/rm":
            return engine.remove(id) ? json("200 OK", ["ok": true]) : bad("404 Not Found", "no trigger \(id)")

        case "/fleet-triggers/fire":
            if let why = engine.fire(id) {
                return bad(why == "no such trigger" ? "404 Not Found" : "409 Conflict", why)
            }
            return json("200 OK", ["ok": true])

        case "/fleet-triggers/pause":
            guard let t = engine.setPaused(id, query["on"] != "0") else { return bad("404 Not Found", "no trigger \(id)") }
            return json("200 OK", fleetTriggerJSON(FleetTriggerStatus(trigger: t, running: false)))

        case "/fleet-triggers/log":
            guard let text = engine.log(id, lines: Int(query["n"] ?? "") ?? 200) else {
                return bad("404 Not Found", "no trigger \(id)")
            }
            return json("200 OK", ["log": text])

        case "/fleet-triggers/restore":
            guard let t = engine.get(id) else { return bad("404 Not Found", "no trigger \(id)") }
            let (status, body) = restoreFleetTriggerSource(t)
            return json(status, body)

        default:
            return bad("404 Not Found", "no such route")
        }
    }

    /// The card a call came from, if it is one: its uuid, name and current conversation. A call
    /// from a plain shell, or from another trigger, has no card behind it.
    private func fleetTriggerSource(_ caller: String?) -> (String?, String?, String?) {
        guard let raw = caller?.trimmingCharacters(in: .whitespaces), let id = UUID(uuidString: raw) else {
            return (nil, nil, nil)
        }
        if let t = terminals.first(where: { $0.id == id }) {
            return (id.uuidString, t.name, lastSessionFile(for: t))
        }
        if let a = terminalArchive.first(where: { $0.id == id }) {
            return (id.uuidString, a.name, a.transcriptPath)
        }
        return (id.uuidString, nil, nil)
    }

    /// The trigger as the API shows it: the stored fields, whether it is running, and what has
    /// become of its source card since — so a list can say "removed" rather than show a dead id.
    func fleetTriggerJSON(_ s: FleetTriggerStatus) -> [String: Any] {
        var out = ((try? FleetTriggerEngine.encoder.encode(s.trigger))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        out["running"] = s.running
        if let src = s.trigger.source, let id = UUID(uuidString: src) {
            if let t = terminals.first(where: { $0.id == id }) {
                out["sourceCard"] = ["state": "board", "name": t.name, "status": t.status.apiLabel]
            } else if let a = terminalArchive.first(where: { $0.id == id }) {
                out["sourceCard"] = ["state": "removed", "name": a.name]
            } else {
                out["sourceCard"] = ["state": "gone"]
            }
        }
        return out
    }

    /// Bring back the card that set a trigger up, in its latest conversation.
    ///
    /// Whatever has happened to it: still open → raised; closed → reopened, resuming the last
    /// session it had; removed → restored from the drawer under its own name and id; gone from both
    /// → its conversation from when it made the trigger, in a new card.
    func restoreFleetTriggerSource(_ trig: FleetTrigger) -> (status: String, body: [String: Any]) {
        func sid(_ path: String) -> String {
            AgentHome.isCodex(path) ? CodexTree.sessionId(fromRollout: path)
                                    : ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        if let src = trig.source, let id = UUID(uuidString: src) {
            if let t = terminals.first(where: { $0.id == id }) {
                if t.status == .closed || t.status == .exited {
                    reopenTerminal(id)
                    return ("200 OK", ["ok": true, "action": "reopened", "id": id.uuidString, "name": t.name])
                }
                raiseTerminal(id)
                return ("200 OK", ["ok": true, "action": "already_open", "id": id.uuidString, "name": t.name])
            }
            if let a = terminalArchive.first(where: { $0.id == id }),
               let path = a.transcriptPath ?? trig.sourceTranscript {
                return restoreConversation(path: path, sid: a.sessionId ?? sid(path))
            }
        }
        if let path = trig.sourceTranscript, FileManager.default.fileExists(atPath: path) {
            return restoreConversation(path: path, sid: sid(path), newName: trig.sourceName)
        }
        return ("404 Not Found", ["error": trig.source == nil
            ? "this trigger was not set up from a card"
            : "its card is gone and no conversation of it is left to resume"])
    }
}
