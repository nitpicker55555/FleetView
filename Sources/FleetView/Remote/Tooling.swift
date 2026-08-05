import Foundation
import Darwin

/// Small helpers for finding CLI tools (tmux/ttyd) from a GUI app (whose PATH is minimal),
/// discovering the machine's LAN address, and picking a free TCP port for ttyd.
enum Tooling {
    private static let commonDirs = [
        "/opt/homebrew/bin/", "/opt/homebrew/sbin/",
        "/usr/local/bin/", "/usr/local/sbin/",
        "/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/",
    ]

    /// Resolve a tool to an absolute path. GUI-launched apps get a bare PATH, so we probe the
    /// usual install dirs first (fast, no subprocess), then fall back to asking a login shell.
    static func find(_ name: String) -> String? {
        for dir in commonDirs {
            let p = dir + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // Fallback: a login shell knows the user's real PATH (Homebrew, asdf, etc.).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: FV.userShell)
        proc.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }

    /// The Mac's primary LAN IPv4 (prefers en0/en1 — Wi-Fi/Ethernet — over VPN/utun interfaces).
    static func lanIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }   // skip utun/awdl/bridge/etc.
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                                 socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard ok == 0 else { continue }
            let ip = String(cString: host)
            if !ip.isEmpty { candidates.append((name, ip)) }
        }
        // en0 before en1 before enN → the built-in Wi-Fi/Ethernet is usually the reachable one.
        return candidates.sorted { $0.name < $1.name }.first?.ip
    }

    /// The Mac's Tailscale IPv4, if the tailnet is up (address in the 100.64.0.0/10 CGNAT range,
    /// usually on a utun interface). This is reachable from any device on the same tailnet.
    static func tailscaleIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let p = ip.split(separator: ".").compactMap { Int($0) }
            if p.count == 4, p[0] == 100, (64...127).contains(p[1]) { return ip }   // 100.64.0.0/10
        }
        return nil
    }

    /// IP to show in the UI (QR / copy link): prefer Tailscale (works off-LAN too), else the LAN IP.
    static func preferredIP() -> String? { tailscaleIP() ?? lanIP() }

    /// Can we bind this TCP port right now? Used to hand ttyd a free port.
    static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    /// Block until something accepts a connection on this port, or the deadline passes.
    ///
    /// `Process.run()` returns when the child is spawned, not when it is listening — ttyd binds
    /// about 20ms later. Handing the port to the browser in that gap gets the iframe a connection
    /// refused, which renders as a blank rectangle with no event the page can hook. Measured across
    /// this Mac's audit + ttyd logs: 22% of cold terminal opens landed in that gap.
    ///
    /// Polling a socket is crude, but it is the only signal ttyd gives us — it has no ready pipe,
    /// and its "Listening on port" line goes to a log shared by every instance.
    static func waitForPort(_ port: Int, timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd >= 0 {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(UInt16(port).bigEndian)
                addr.sin_addr.s_addr = INADDR_ANY      // 0.0.0.0 → loopback for connect()
                let ok = withUnsafePointer(to: &addr) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                } == 0
                close(fd)
                if ok { return true }
            }
            usleep(5_000)
        }
        return false
    }
}
