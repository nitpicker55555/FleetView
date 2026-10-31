import Foundation

/// Publishes a conversation page where people without FleetView can read it, and takes it down
/// again. FleetView's own server is LAN- and tailnet-only by design, so a link anyone can open has
/// to live somewhere else: a small HTTP service that stores the page and answers with its public URL.
///
/// The service is named in `~/.fleetview/share.json`, never in this source:
///
///     {"endpoint": "https://example.com", "token": "…"}
///
/// It takes `POST <endpoint>/api/shares` with `{"title","html"}` and a Bearer token, answers
/// `{"id","url"}`, and `DELETE <endpoint>/api/shares/<id>` withdraws one. The token lives here and
/// not in the web page because that page is served without auth to the whole LAN; the page asks
/// FleetView, and FleetView asks the service.
enum ShareService {
    struct Config: Decodable {
        let endpoint: String
        let token: String
    }

    struct Published { let id: String; let url: String }

    enum Failure: Error {
        case notConfigured
        case rejected(Int, String)
        case unreachable(String)

        var isNotConfigured: Bool { if case .notConfigured = self { return true } else { return false } }

        var message: String {
            switch self {
            case .notConfigured:
                return "no share service configured — put {\"endpoint\",\"token\"} in ~/.fleetview/share.json"
            case .rejected(let code, let why): return "the share service said \(code): \(why)"
            case .unreachable(let why): return "could not reach the share service: \(why)"
            }
        }
    }

    static var configFile: URL { FV.supportDir.appendingPathComponent("share.json") }

    /// Read on every share, so editing the file takes effect without a relaunch.
    static func config() -> Config? {
        guard let data = try? Data(contentsOf: configFile),
              let c = try? JSONDecoder().decode(Config.self, from: data),
              !c.endpoint.isEmpty, !c.token.isEmpty else { return nil }
        return c
    }

    /// One session for these calls only: a whole conversation is a few MB, and the default 60 s
    /// request timeout is for the bytes trickling in, which a slow uplink can exceed.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 180
        return URLSession(configuration: cfg)
    }()

    static func publish(html: Data, title: String,
                        completion: @escaping @Sendable (Result<Published, Failure>) -> Void) {
        guard let c = config(), let url = URL(string: c.endpoint.trimmingTrailingSlashes + "/api/shares")
        else { completion(.failure(.notConfigured)); return }
        let payload: [String: Any] = ["title": title, "html": String(decoding: html, as: UTF8.self)]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(.rejected(0, "could not encode the page"))); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
        call(req) { result in
            completion(result.flatMap { json in
                guard let id = json["id"] as? String, let link = json["url"] as? String else {
                    return .failure(.rejected(200, "no id/url in the answer"))
                }
                return .success(Published(id: id, url: link))
            })
        }
    }

    static func withdraw(id: String, completion: @escaping @Sendable (Result<Void, Failure>) -> Void) {
        guard let c = config(),
              let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: c.endpoint.trimmingTrailingSlashes + "/api/shares/" + escaped)
        else { completion(.failure(.notConfigured)); return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
        call(req) { completion($0.map { _ in () }) }
    }

    private static func call(_ req: URLRequest,
                             completion: @escaping @Sendable (Result<[String: Any], Failure>) -> Void) {
        session.dataTask(with: req) { data, response, error in
            if let error { completion(.failure(.unreachable(error.localizedDescription))); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            guard (200..<300).contains(code) else {
                let why = json["error"] as? String
                    ?? data.map { String(decoding: $0.prefix(200), as: UTF8.self) } ?? ""
                completion(.failure(.rejected(code, why))); return
            }
            completion(.success(json))
        }.resume()
    }
}

private extension String {
    var trimmingTrailingSlashes: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
