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

/// A note on a peer's sidebar list.
struct PeerNote: Identifiable, Hashable {
    let id: String
    let text: String
}

/// One terminal on a peer, with the id you address it by from here.
struct PeerTerminal: Identifiable, Hashable {
    let id: String
    let name: String
    let status: String
    let project: String
}

/// What a peer reports about itself beyond the card board — read natively rather than looked for in
/// the embedded page, because the page only shows its Notes inside a terminal's composer. Somebody
/// switching to a peer to *read its notes* would find the board and no notes anywhere on it.
struct PeerDetail {
    var notes: [PeerNote] = []
    var terminals: [PeerTerminal] = []
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
    /// The subnet was too large to sweep whole, so only this machine's own /24 was looked at. Shown
    /// in the strip: a short list that quietly covered a slice of the network reads as "nobody is
    /// out there", which is the one conclusion it does not support.
    @Published private(set) var narrowed = false
    @Published private(set) var sweepSize = 0

    private static let ports = [8080, 8081, 8082]
    /// Above this many host addresses, fall back to the local /24. A /16 is 65534 addresses and
    /// three ports each — not a scan anyone waits for.
    /// nonisolated: the sweep runs off the main actor, and under Swift 6 reading a main-actor
    /// static from there is an error rather than a warning.
    nonisolated static let hostCap = 4096

    /// Returns the peers still present, so the caller can drop a selection that has gone away —
    /// which lives on AppState, because the content column has to redraw when it changes and a
    /// change buried in this object would not reach it.
    @discardableResult
    func scan() async -> [Peer] {
        guard !scanning else { return found }
        scanning = true
        narrowed = false
        let (hosts, slow, mine, cut) = Self.sweepTargets()
        narrowed = cut
        sweepSize = hosts.count
        let hits = await Self.probeAll(hosts: hosts, slow: slow, ports: Self.ports, mine: mine)
        found = hits.sorted {
            if $0.isSelf != $1.isSelf { return $0.isSelf }      // this machine first
            return ($0.host, $0.port) < ($1.host, $1.port)
        }
        scanned = true
        scanning = false
        return found
    }

    /// One peer's notes and terminals. Same `/state` the switcher already identifies peers by, asked
    /// again on demand: it is a few KB and only fetched for the peer you are actually looking at.
    nonisolated static func detail(for peer: Peer) async -> PeerDetail? {
        guard let url = URL(string: peer.url + "/state") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var out = PeerDetail()
        for n in (obj["notes"] as? [[String: Any]]) ?? [] {
            guard let id = n["id"] as? String, let text = n["text"] as? String else { continue }
            out.notes.append(PeerNote(id: id, text: text))
        }
        let projects = (obj["projects"] as? [[String: Any]]) ?? []
        var projectName: [String: String] = [:]
        for p in projects {
            if let id = p["id"] as? String { projectName[id] = (p["name"] as? String) ?? "" }
        }
        for t in (obj["terminals"] as? [[String: Any]]) ?? [] {
            guard let id = t["id"] as? String else { continue }
            out.terminals.append(PeerTerminal(id: id,
                                              name: (t["name"] as? String) ?? "",
                                              status: (t["status"] as? String) ?? "",
                                              project: projectName[(t["projectId"] as? String) ?? ""] ?? ""))
        }
        return out
    }

    // MARK: - Probing

    private nonisolated static func probeAll(hosts: [String], slow: Set<String>, ports: [Int],
                                             mine: Set<String>) async -> [Peer] {
        var targets: [(host: String, port: Int, timeout: TimeInterval)] = []
        for h in hosts {
            // A LAN probe has to stay short — it is multiplied by thousands of addresses. A tailnet
            // hop is a different animal: ~700ms round trip, and `/state` came back in 2.0s from a
            // machine that was up the whole time. At the LAN timeout it never answered in time, and
            // "timed out" is indistinguishable from "not running FleetView". There are only a
            // handful of tailnet addresses, so the wait is affordable exactly where it is needed.
            let t: TimeInterval = slow.contains(h) ? 8 : 1.5
            for p in ports { targets.append((h, p, t)) }
        }
        guard !targets.isEmpty else { return [] }
        // Bounded fan-out: thousands of sockets opened at once is a burst some routers answer by
        // dropping the lot, which reads back as "no peers on this network". Raised from 64 once the
        // sweep stopped assuming /24 — a /21 is eight times the addresses and the wait showed.
        let inFlight = 128
        return await withTaskGroup(of: Peer?.self) { group in
            var out: [Peer] = []
            var next = 0
            func launch() {
                guard next < targets.count else { return }
                let t = targets[next]
                next += 1
                group.addTask { await probe(host: t.host, port: t.port, timeout: t.timeout, mine: mine) }
            }
            for _ in 0..<min(inFlight, targets.count) { launch() }
            while let result = await group.next() {
                if let result { out.append(result) }
                launch()
            }
            return out
        }
    }

    private nonisolated static func probe(host: String, port: Int, timeout: TimeInterval,
                                          mine: Set<String>) async -> Peer? {
        guard let url = URL(string: "http://\(host):\(port)/state") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
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

    /// Every address to probe, plus our own (for the "←self" mark) and whether the sweep was cut short.
    ///
    /// The subnet comes from the interface's real netmask, not from chopping the last octet off our
    /// address. That shortcut is a hidden assumption that every network is a /24, and it is wrong in
    /// a way that looks like success: on a 255.255.248.0 network — a /21, eight /24s joined — it
    /// probes an eighth of the addresses, misses even the gateway, and reports "no peers found".
    private nonisolated static func sweepTargets() -> (hosts: [String], slow: Set<String>,
                                                       mine: Set<String>, narrowed: Bool) {
        var mine: Set<String> = []
        var ifaces: [(ip: UInt32, mask: UInt32)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return ([], [], [], false) }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let netmask = ptr.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let text = ipv4String(ip)
            mine.insert(text)
            // A self-assigned 169.254 address means the DHCP lease never arrived; there is no
            // subnet there to find anybody on.
            guard !text.hasPrefix("169.254."), mask != 0 else { continue }
            // /31 and /32 are point-to-point and tunnel interfaces — one address, no subnet to
            // enumerate. Tailscale is the one that matters here, and it is reached by asking it
            // for its peers rather than by sweeping (see `tailnetHosts`).
            guard mask < 0xFFFF_FFFE else { continue }
            ifaces.append((ip, mask))
        }
        var hosts: [String] = []
        var seenNets: Set<UInt32> = []
        var narrowed = false
        for iface in ifaces {
            let (addrs, cut) = hostAddresses(ip: iface.ip, mask: iface.mask, cap: hostCap)
            if cut { narrowed = true }
            // Two interfaces on the same subnet (Wi-Fi and Ethernet into one switch) would
            // otherwise have every address probed twice.
            guard seenNets.insert(iface.ip & (cut ? 0xFFFF_FF00 : iface.mask)).inserted else { continue }
            hosts.append(contentsOf: addrs)
        }
        // The tailnet is not on any subnet we could walk, so its members are added by name. Our own
        // tailnet address is already in `mine`: the interface walk records every address it sees
        // before deciding whether the subnet is worth sweeping.
        var seenHost = Set(hosts)
        var slow: Set<String> = []
        for h in tailnetHosts() {
            slow.insert(h)                      // reached over the tunnel, so it gets the long wait
            if seenHost.insert(h).inserted { hosts.append(h) }
        }
        return (hosts, slow, mine, narrowed)
    }

    /// Every IPv4 address on this tailnet, from Tailscale itself.
    ///
    /// A tailnet cannot be swept and there is no point pretending otherwise: the interface carries a
    /// /32 — one address, no subnet — and the range it sits in, 100.64.0.0/10, is four million
    /// addresses. The node already knows every peer by name and address, so this asks rather than
    /// looks. That is also why a Tailscale machine never showed up in the LAN scan: there was
    /// nothing for a subnet sweep to find.
    ///
    /// Absolute paths because a GUI app inherits almost no PATH; offline peers are skipped so the
    /// probe does not spend its timeout on machines that are known to be down.
    private nonisolated static func tailnetHosts() -> [String] {
        let candidates = ["/usr/local/bin/tailscale",
                          "/opt/homebrew/bin/tailscale",
                          "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["status", "--json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var out: [String] = []
        func collect(_ node: [String: Any], skipOffline: Bool) {
            if skipOffline, (node["Online"] as? Bool) != true { return }
            for ip in (node["TailscaleIPs"] as? [String]) ?? [] where !ip.contains(":") {
                out.append(ip)      // IPv4 only; the v6 half of a tailnet address reaches the same node
            }
        }
        if let me = obj["Self"] as? [String: Any] { collect(me, skipOffline: false) }
        for (_, peer) in (obj["Peer"] as? [String: [String: Any]]) ?? [:] {
            collect(peer, skipOffline: true)
        }
        return out
    }

    /// Every host address in the subnet holding `ip`, excluding the network and broadcast addresses.
    /// Falls back to the enclosing /24 when the subnet is bigger than `cap`, reporting that it did.
    /// Pure arithmetic, kept separate from `getifaddrs` so it can be checked without a network.
    nonisolated static func hostAddresses(ip: UInt32, mask: UInt32,
                                          cap: Int) -> (hosts: [String], narrowed: Bool) {
        let size = UInt64(~mask) + 1
        let narrowed = size > UInt64(cap)
        let effective: UInt32 = narrowed ? 0xFFFF_FF00 : mask
        let net = ip & effective
        let last = ~effective                     // broadcast offset; hosts run 1..<last
        guard last > 1 else { return ([ipv4String(net)], narrowed) }   // /31, /32: no room to split
        var out: [String] = []
        out.reserveCapacity(Int(last) - 1)
        var h: UInt32 = 1
        while h < last { out.append(ipv4String(net | h)); h += 1 }
        return (out, narrowed)
    }

    nonisolated static func ipv4String(_ v: UInt32) -> String {
        "\((v >> 24) & 255).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)"
    }
}
