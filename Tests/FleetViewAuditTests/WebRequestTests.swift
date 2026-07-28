import Foundation
import FleetViewAudit

final class WebRequestTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - IP classification

    func testLoopbackIsRecognised() {
        XCTAssertEqual(IPScope.classify("127.0.0.1"), .loopback)
        XCTAssertEqual(IPScope.classify("::1"), .loopback)
    }

    func testPrivateRangesAreLAN() {
        for ip in ["192.168.1.24", "10.0.0.5", "172.16.3.9", "172.31.255.254", "169.254.1.1"] {
            XCTAssertEqual(IPScope.classify(ip), .lan, "\(ip) should be LAN")
        }
    }

    func testCGNATRangeIsTailscale() {
        // Running a geo database against these would be meaningless; Tailscale's own identity is
        // the useful answer, so they have to be told apart from ordinary public addresses.
        XCTAssertEqual(IPScope.classify("100.101.7.23"), .tailscale)
        XCTAssertEqual(IPScope.classify("100.64.0.1"), .tailscale)
        XCTAssertEqual(IPScope.classify("100.127.255.255"), .tailscale)
    }

    func testAddressesJustOutsideCGNATAreNotTailscale() {
        XCTAssertEqual(IPScope.classify("100.63.255.255"), .publicNet)
        XCTAssertEqual(IPScope.classify("100.128.0.1"), .publicNet)
    }

    func testPublicAddressesAreRecognised() {
        XCTAssertEqual(IPScope.classify("8.8.8.8"), .publicNet)
        XCTAssertEqual(IPScope.classify("172.32.0.1"), .publicNet)   // just outside 172.16/12
    }

    func testIPv4MappedIPv6IsUnwrapped() {
        XCTAssertEqual(IPScope.classify("::ffff:192.168.1.24"), .lan)
    }

    // MARK: - Request parsing

    private func head(_ raw: String) -> HTTPRequestHead? { HTTPRequestHead(raw: raw) }

    func testRequestLineAndQueryAreParsed() throws {
        let request = try XCTUnwrap(head("GET /action?id=abc&do=rename&name=new%20name HTTP/1.1\r\nHost: x\r\n"))
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/action")
        XCTAssertEqual(request.query["id"], "abc")
        XCTAssertEqual(request.query["do"], "rename")
        XCTAssertEqual(request.query["name"], "new name")
    }

    func testHeaderNamesAreCaseInsensitive() throws {
        let request = try XCTUnwrap(head("GET / HTTP/1.1\r\nUSER-AGENT: probe/1\r\nAccept-Language: zh-CN\r\n"))
        XCTAssertEqual(request.userAgent, "probe/1")
        XCTAssertEqual(request.acceptLanguage, "zh-CN")
    }

    func testCookiesAreParsed() throws {
        let request = try XCTUnwrap(head("GET / HTTP/1.1\r\nCookie: fv_ws=ws_123; theme=dark\r\n"))
        XCTAssertEqual(request.cookies["fv_ws"], "ws_123")
        XCTAssertEqual(request.cookies["theme"], "dark")
    }

    func testMissingCookieHeaderIsEmpty() throws {
        let request = try XCTUnwrap(head("GET / HTTP/1.1\r\nHost: x\r\n"))
        XCTAssertTrue(request.cookies.isEmpty)
    }

    func testForwardedForKeepsOnlyTheFirstHop() throws {
        let request = try XCTUnwrap(head("GET / HTTP/1.1\r\nX-Forwarded-For: 100.64.0.2, 10.0.0.1\r\n"))
        XCTAssertEqual(request.forwardedFor, "100.64.0.2")
    }

    func testFleetViewToolsIdentifyThemselves() throws {
        // Without this the CLI scripts would be logged as anonymous browsers.
        let ua = try XCTUnwrap(head("GET /state HTTP/1.1\r\nUser-Agent: fleetctl/project-manager/1.0\r\n"))
        XCTAssertEqual(ua.cliTool, "project-manager")
        let explicit = try XCTUnwrap(head("GET /state HTTP/1.1\r\nX-FleetView-Actor: fleet-monitor\r\n"))
        XCTAssertEqual(explicit.cliTool, "fleet-monitor")
        let browser = try XCTUnwrap(head("GET /state HTTP/1.1\r\nUser-Agent: Mozilla/5.0\r\n"))
        XCTAssertNil(browser.cliTool)
    }

    func testMalformedRequestsAreRejected() {
        XCTAssertNil(head(""))
        XCTAssertNil(head("GARBAGE"))
    }

    // MARK: - Which paths deserve a line each

    func testPolledEndpointsAreNotAuditedPerRequest() {
        // /state alone is ~2,400 requests per idle half-hour.
        for path in ["/state", "/conversation", "/panel-meta", "/panel-data", "/capture", "/tree"] {
            XCTAssertTrue(WebPathPolicy.isPolled(path), "\(path) polls")
            XCTAssertFalse(WebPathPolicy.isAudited(path), "\(path) must not produce a line per request")
        }
    }

    func testMutatingEndpointsAreAudited() {
        for path in ["/action", "/type", "/key", "/new", "/note", "/ask", "/open", "/select", "/scroll"] {
            XCTAssertTrue(WebPathPolicy.isAudited(path), "\(path) must be audited")
        }
    }

    func testDocumentsAreNotAuditedPerRequest() {
        XCTAssertFalse(WebPathPolicy.isAudited("/"))
        XCTAssertFalse(WebPathPolicy.isAudited("/panel"))
    }

    // MARK: - Sessions

    func testFirstRequestStartsASession() {
        let registry = WebSessionRegistry()
        let observed = registry.observe(id: nil, ip: "100.101.7.23", userAgent: "Mozilla/5.0 (iPhone)",
                                        path: "/", now: now)
        XCTAssertTrue(observed.isNew)
        XCTAssertEqual(observed.session.scope, .tailscale)
        XCTAssertEqual(observed.session.requests, 1)
    }

    func testKnownSessionIsReused() {
        let registry = WebSessionRegistry()
        let first = registry.observe(id: nil, ip: "10.0.0.5", userAgent: "x", path: "/", now: now)
        let second = registry.observe(id: first.session.id, ip: "10.0.0.5", userAgent: "x",
                                      path: "/state", now: now.addingTimeInterval(2))
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(second.session.id, first.session.id)
        XCTAssertEqual(second.session.totalRequests, 2)
    }

    func testACookielessPollerReusesItsSession() {
        // A scripted client keeps no cookie. Minting a session per request turned 13 minutes of
        // fleet-monitor polling into 227 "session started" records, which is noise, not a log.
        let registry = WebSessionRegistry()
        let first = registry.observe(id: nil, ip: "127.0.0.1", userAgent: "Python-urllib/3.14",
                                     path: "/state", now: now)
        var newSessions = first.isNew ? 1 : 0
        for i in 1...50 {
            let next = registry.observe(id: nil, ip: "127.0.0.1", userAgent: "Python-urllib/3.14",
                                        path: "/state", now: now.addingTimeInterval(Double(i) * 2))
            if next.isNew { newSessions += 1 }
        }
        XCTAssertEqual(newSessions, 1, "50 polls must be one visit")
        XCTAssertEqual(registry.activeCount, 1)
    }

    func testDifferentCookielessClientsStaySeparate() {
        let registry = WebSessionRegistry()
        _ = registry.observe(id: nil, ip: "127.0.0.1", userAgent: "Python-urllib/3.14", path: "/state", now: now)
        let other = registry.observe(id: nil, ip: "192.168.2.8", userAgent: "Python-urllib/3.14",
                                     path: "/state", now: now)
        let tool = registry.observe(id: nil, ip: "127.0.0.1", userAgent: "fleetctl/fleet-monitor/1.0",
                                    path: "/state", now: now)
        XCTAssertTrue(other.isNew, "a different address is a different client")
        XCTAssertTrue(tool.isNew, "a different tool is a different client")
        XCTAssertEqual(registry.activeCount, 3)
    }

    func testACookieAlwaysWinsOverTheFallback() {
        let registry = WebSessionRegistry()
        let a = registry.observe(id: nil, ip: "10.0.0.5", userAgent: "Safari", path: "/", now: now)
        let b = registry.observe(id: "ws_explicit", ip: "10.0.0.5", userAgent: "Safari",
                                 path: "/", now: now.addingTimeInterval(1))
        XCTAssertNotEqual(b.session.id, a.session.id, "an explicit cookie identifies its own session")
    }

    func testACookielessClientDoesNotAdoptAnExpiredSession() {
        let registry = WebSessionRegistry(idleTimeout: 60)
        let first = registry.observe(id: nil, ip: "127.0.0.1", userAgent: "curl", path: "/", now: now)
        let later = registry.observe(id: nil, ip: "127.0.0.1", userAgent: "curl",
                                     path: "/", now: now.addingTimeInterval(600))
        XCTAssertTrue(later.isNew)
        XCTAssertNotEqual(later.session.id, first.session.id)
    }

    func testFaviconIsNotAudited() {
        // Every browser asks for it unprompted; its 404 says nothing about anyone's behaviour.
        XCTAssertTrue(WebPathPolicy.isDocument("/favicon.ico"))
        XCTAssertFalse(WebPathPolicy.isAudited("/favicon.ico"))
    }

    func testAStaleCookieStartsAFreshSession() {
        let registry = WebSessionRegistry(idleTimeout: 60)
        let first = registry.observe(id: nil, ip: "10.0.0.5", userAgent: "x", path: "/", now: now)
        let later = registry.observe(id: first.session.id, ip: "10.0.0.5", userAgent: "x",
                                     path: "/", now: now.addingTimeInterval(3600))
        XCTAssertTrue(later.isNew, "a visit an hour later is a new visit")
    }

    func testRollupsCollectPollCountsAndThenReset() {
        let registry = WebSessionRegistry(rollupInterval: 300)
        let session = registry.observe(id: nil, ip: "10.0.0.5", userAgent: "x", path: "/", now: now)
        for i in 1...200 {
            _ = registry.observe(id: session.session.id, ip: "10.0.0.5", userAgent: "x",
                                 path: "/state", bytes: 100, now: now.addingTimeInterval(Double(i)))
        }
        let due = registry.dueRollups(now: now.addingTimeInterval(301))
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due[0].requests, 201)
        XCTAssertEqual(due[0].byPath["/state"], 200)
        XCTAssertEqual(due[0].bytesOut, 20_000)

        // The window closed: a second rollup at the same moment has nothing left to report.
        XCTAssertTrue(registry.dueRollups(now: now.addingTimeInterval(301)).isEmpty)
    }

    func testIdleSessionsExpireAndAreReturnedOnce() {
        let registry = WebSessionRegistry(idleTimeout: 60)
        _ = registry.observe(id: nil, ip: "10.0.0.5", userAgent: "x", path: "/", now: now)
        XCTAssertTrue(registry.expire(now: now.addingTimeInterval(30)).isEmpty)
        XCTAssertEqual(registry.expire(now: now.addingTimeInterval(120)).count, 1)
        XCTAssertEqual(registry.activeCount, 0)
        XCTAssertTrue(registry.expire(now: now.addingTimeInterval(200)).isEmpty)
    }

    func testSelectionChangeIsTracked() {
        let registry = WebSessionRegistry()
        let session = registry.observe(id: nil, ip: "10.0.0.5", userAgent: "x", path: "/", now: now).session
        XCTAssertNil(registry.setSelection("t1", for: session.id))
        XCTAssertEqual(registry.setSelection("t2", for: session.id), "t1")
    }

    func testSessionBecomesAWebActorWithNetworkFields() {
        let registry = WebSessionRegistry()
        let session = registry.observe(id: nil, ip: "100.101.7.23", port: 51544,
                                       userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_4) Safari",
                                       path: "/", now: now).session
        let actor = session.actor
        XCTAssertEqual(actor.kind, .web)
        XCTAssertEqual(actor.sourceIP, "100.101.7.23")
        XCTAssertEqual(actor.sourcePort, 51544)
        XCTAssertEqual(actor.name, "iPhone · Safari")
    }

    func testDeviceLabelsAreReadable() {
        XCTAssertEqual(WebSession.label(userAgent: "Mozilla/5.0 (Macintosh) Chrome/120"), "Mac · Chrome")
        XCTAssertEqual(WebSession.label(userAgent: "Mozilla/5.0 (iPad) Safari"), "iPad · Safari")
        XCTAssertNil(WebSession.label(userAgent: nil))
    }
}
