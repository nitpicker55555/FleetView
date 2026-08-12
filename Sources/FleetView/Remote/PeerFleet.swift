import Foundation

/// Another FleetView answering on this network.
struct Peer: Identifiable, Hashable {
    var id: String { "\(host):\(port)" }
    let host: String
    let port: Int
    /// The macOS account it runs as, inferred from the `/Users/<name>` prefix of any path it
    /// reports. Empty when it has no projects and no terminals — nothing to read it from, which is
    /// not the same as having no user, so the UI says so rather than guessing.
    let user: String
    let terminals: Int
    let working: Int
    let isSelf: Bool

    var url: String { "http://\(host):\(port)" }
    var label: String { user.isEmpty ? host : user }
}

/// Finds the other FleetViews on the LAN and remembers which one the board is showing.
///
/// There is nothing to listen for — no announcement, no registry — so this probes: every address on
/// each local /24, on the ports FleetView picks from. An instance is identified by `/state`
/// answering with the right shape; nothing else on these ports would.
///
/// The scan is only ever started by a person opening the switcher. Sweeping ~760 addresses on a
/// timer, in the background, forever, is the kind of thing that gets an app noticed by other
/// people's firewalls — and the answer is stale in a way nobody is looking at anyway.
@MainActor
final class PeerFleet: ObservableObject {
    @Published private(set) var found: [Peer] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanned = false      // "no peers" only means something after a scan

    private static let ports = [8080, 8081, 8082]

    /// Returns the peers still present, so the caller can drop a selection that has gone away —
    /// which lives on AppState, because the content column has to redraw when it changes and a
    /// change buried in this object would not reach it.
    @discardableResult
    func scan() async -> [Peer] {
        guard !scanning else { return found }
        scanning = true
        let mine = Self.localIPv4()
        let prefixes = Set(mine.map { $0.split(separator: ".").dropLast().joined(separator: ".") })
        let hits = await Self.probeAll(prefixes: Array(prefixes), ports: Self.ports, mine: mine)
        found = hits.sorted {
            if $0.isSelf != $1.isSelf { return $0.isSelf }      // this machine first
            return ($0.host, $0.port) < ($1.host, $1.port)
        }
        scanned = true
        scanning = false
        return found
    }

    // MARK: - Probing

    private nonisolated static func probeAll(prefixes: [String], ports: [Int],
                                             mine: Set<String>) async -> [Peer] {
        var targets: [(host: String, port: Int)] = []
        for pre in prefixes where !pre.isEmpty {
            for h in 1...254 { for p in ports { targets.append(("\(pre).\(h)", p)) } }
        }
        guard !targets.isEmpty else { return [] }
        // Bounded fan-out: 760-odd sockets opened at once is a burst that some routers answer by
        // dropping the lot, which reads back as "no peers on this network".
        let inFlight = 64
        return await withTaskGroup(of: Peer?.self) { group in
            var out: [Peer] = []
            var next = 0
            func launch() {
                guard next < targets.count else { return }
                let t = targets[next]
                next += 1
                group.addTask { await probe(host: t.host, port: t.port, mine: mine) }
            }
            for _ in 0..<min(inFlight, targets.count) { launch() }
            while let result = await group.next() {
                if let result { out.append(result) }
                launch()
            }
            return out
        }
    }

    private nonisolated static func probe(host: String, port: Int, mine: Set<String>) async -> Peer? {
        guard let url = URL(string: "http://\(host):\(port)/state") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let terms = obj["terminals"] as? [[String: Any]],
              let projects = obj["projects"] as? [[String: Any]] else { return nil }
        return Peer(host: host, port: port,
                    user: inferredUser(projects: projects, terminals: terms),
                    terminals: terms.count,
                    working: terms.filter { ($0["status"] as? String) == "working" }.count,
                    isSelf: mine.contains(host))
    }

    /// `/state` has no user field; every path it does report starts with `/Users/<name>`.
    private nonisolated static func inferredUser(projects: [[String: Any]],
                                                 terminals: [[String: Any]]) -> String {
        var paths: [String] = projects.compactMap { $0["path"] as? String }
        for t in terminals {
            if let c = t["cwd"] as? String { paths.append(c) }
            if let t = t["transcript"] as? String { paths.append(t) }
        }
        var names: Set<String> = []
        for p in paths where p.hasPrefix("/Users/") {
            let rest = p.dropFirst("/Users/".count)
            guard let slash = rest.firstIndex(of: "/") else { continue }
            let name = String(rest[rest.startIndex..<slash])
            if !name.isEmpty && name != "Shared" { names.insert(name) }   // /Users/Shared is nobody
        }
        return names.sorted().joined(separator: "/")
    }

    // MARK: - This machine

    /// Our own IPv4 addresses, which give both the subnets to sweep and the "←self" marker.
    /// Read from the interface list rather than by shelling out to `ipconfig`, so it costs nothing
    /// and works on whatever the interfaces happen to be called.
    private nonisolated static func localIPv4() -> Set<String> {
        var out: Set<String> = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buf)
            // Self-assigned 169.254.x addresses have no subnet worth sweeping.
            if !ip.isEmpty && !ip.hasPrefix("169.254.") { out.insert(ip) }
        }
        return out
    }
}
