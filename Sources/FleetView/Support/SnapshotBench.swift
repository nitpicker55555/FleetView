import AppKit
import Combine
import SwiftUI

/// `FV_SNAPSHOT_BENCH=1 FleetView --snapshot <dir>`: what the board costs the main thread, for
/// comparing two builds.
///
/// Scrolling the real board stuttered (2026-11-10) and the causes could only be measured on the
/// running app, with Instruments, while someone scrolled — no way to check a fix before deploying it.
/// This draws the real `DashboardView` in a window ordered in far off screen, as `FV_SNAPSHOT_ANIM`
/// does (a window never shown runs no display cycle), and times three things in main-thread CPU:
///
///  * nothing happening, so only the clocks run;
///  * the writes a running card makes all day — a token refresh, an activity stamp — one at a time;
///  * scrolling the board with pixel wheel events, a frame's worth of time per step.
///
/// The board is the scratch home's `state.json` when there is one (copy the real one in to measure
/// the real board), else the sample. `FV_BENCH_STATE=<file>` takes card statuses from a saved copy of
/// the web API's `/state`, and `FV_BENCH_WORKING=<n>` makes sure that many cards are running.
/// Results go to stderr and `<dir>/bench.txt`.
@MainActor
enum SnapshotBench {
    static var requested: Bool { ProcessInfo.processInfo.environment["FV_SNAPSHOT_BENCH"] != nil }

    static func run(_ state: AppState, size: NSSize, into dir: String, sample: (AppState) -> Void) {
        let env = ProcessInfo.processInfo.environment
        // A process with no window in front is a candidate for App Nap and the efficiency cores,
        // and the same build measured 3x apart from one run to the next until it said otherwise.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: "benchmark")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        if FileManager.default.fileExists(atPath: FV.stateFile.path) { state.load() } else { sample(state) }
        applyStatuses(state, from: env["FV_BENCH_STATE"], working: Int(env["FV_BENCH_WORKING"] ?? "") ?? 0)
        // FV_BENCH_SIDEBAR=hidden|notes|tasks|both: the sidebar folded away, or open with its
        // terminal list, its notes or both unfolded. Unset, as the state file has it.
        switch env["FV_BENCH_SIDEBAR"] {
        case "hidden": state.sidebarHidden = true
        case "notes": state.sidebarHidden = false; state.tasksCollapsed = true; state.notesCollapsed = false
        case "tasks": state.sidebarHidden = false; state.tasksCollapsed = false; state.notesCollapsed = true
        case "both": state.sidebarHidden = false; state.tasksCollapsed = false; state.notesCollapsed = false
        default: break
        }

        NSApp.appearance = NSAppearance(named: .darkAqua)
        let host = DashboardView.host(state)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()

        let meter = StallMeter()
        var publishes = 0
        let counter = state.objectWillChange.sink { _ in publishes += 1 }
        defer { counter.cancel() }
        var out = ""
        func say(_ s: String) { out += s + "\n"; FileHandle.standardError.write(Data((s + "\n").utf8)) }
        let working = state.terminals.indices.filter { state.terminals[$0].status == .working }
        say("board: \(state.projects.count) projects, \(state.terminals.count) cards, \(working.count) working; "
            + "sidebar \(state.sidebarHidden ? "hidden" : "open"), terminals \(state.tasksCollapsed ? "folded" : "open"), "
            + "\(state.notes.count) notes \(state.notesCollapsed ? "folded" : "open")")

        // Token curves are rebuilt from the transcripts in the background after load(); let that
        // and the first layouts finish before anything is timed.
        spin(Double(ProcessInfo.processInfo.environment["FV_BENCH_SETTLE"] ?? "") ?? 8)

        // 1. Idle: the clocks.
        meter.reset()
        publishes = 0
        let idleSeconds = Double(ProcessInfo.processInfo.environment["FV_BENCH_IDLE"] ?? "") ?? 20
        let idleCPU = cpu { spin(idleSeconds) }
        let idlePerSecond = idleCPU / idleSeconds
        say(String(format: "idle %.0fs: %.1f ms main-thread CPU per second; stretches %@; AppState publishes: %d",
                   idleSeconds, idlePerSecond, meter.summary, publishes))

        // 2. The writes a running card makes, each followed by a quarter second for the board to answer.
        let window2 = 0.25
        var writeCosts: [Double] = []
        var writeStalls: [Double] = []
        let targets = working.isEmpty ? Array(state.terminals.indices.prefix(3)) : working
        let writes = Int(ProcessInfo.processInfo.environment["FV_BENCH_WRITES"] ?? "") ?? 60
        for n in 0..<writes where !targets.isEmpty {
            let i = targets[n % targets.count]
            let id = state.terminals[i].id
            meter.reset()
            let c = cpu {
                if n % 2 == 0 {
                    var series = state.tokenSeries[id] ?? []
                    let total = state.terminals[i].newTokens + 1_234
                    series.append(TokenSample(t: Date(), newTokens: total))
                    state.applyTokenRefresh(id, series: series, total: total)
                } else {
                    state.terminals[i].lastActivity = Date()
                }
                spin(window2)
            }
            writeCosts.append(max(0, c - idlePerSecond * window2))
            writeStalls.append(meter.longest)
        }
        if !writeCosts.isEmpty {
            say(String(format: "live write: median %.1f ms, max %.1f ms CPU each; longest stretch median %.1f, max %.1f ms",
                       median(writeCosts), writeCosts.max() ?? 0, median(writeStalls), writeStalls.max() ?? 0))
        }

        // 3. Scrolling: down two screens and back, 12 px a step, one 120 Hz frame per step. Moved
        // through the clip view — a window that is never key takes no wheel events — which is the
        // same bounds change a wheel ends in.
        if let scroll = boardScrollView(in: host) {
            var steps: [Double] = []
            meter.reset()
            publishes = 0
            let frame = 1.0 / 120
            let clip = scroll.contentView
            let docHeight = scroll.documentView?.frame.height ?? 0
            let room = max(0, docHeight - clip.bounds.height)
            var reached: CGFloat = 0
            let rounds = Int(ProcessInfo.processInfo.environment["FV_BENCH_SCROLLS"] ?? "") ?? 1
            let total = cpu {
                for k in 0..<(160 * rounds) {
                    let j = k % 160
                    let y = min(room, CGFloat(j < 80 ? j + 1 : 159 - j) * 12)
                    reached = max(reached, y)
                    steps.append(cpu {
                        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                        scroll.reflectScrolledClipView(clip)
                        spin(frame)
                    })
                }
            }
            let over = steps.filter { $0 > frame * 1000 }.count
            say(String(format: "scroll (%@, document %.0f px): %d steps to %.0f px and back, %.0f ms CPU (%.1f per step, p90 %.1f, max %.1f); steps over a frame: %d; stretches %@; publishes %d",
                       String(describing: type(of: scroll)), docHeight,
                       steps.count, reached, total, total / Double(max(1, steps.count)), percentile(steps, 0.9),
                       steps.max() ?? 0, over, meter.summary, publishes))
        } else {
            say("scroll: no scroll view found")
        }
        window.orderOut(nil)
        try? out.write(toFile: dir + "/bench.txt", atomically: true, encoding: .utf8)
    }

    /// Statuses as the live board had them, then enough running cards to make `working`.
    private static func applyStatuses(_ state: AppState, from path: String?, working: Int) {
        let now = Date()
        if let path, let data = FileManager.default.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rows = json["terminals"] as? [[String: Any]] {
            for row in rows {
                guard let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)),
                      let i = state.terminals.firstIndex(where: { $0.id == id }),
                      let s = (row["status"] as? String).flatMap(TermStatus.init(rawValue:)) else { continue }
                state.terminals[i].status = s
                if s == .working, let r = row["running"] as? Double, r >= 0 {
                    state.terminals[i].runningSince = now.addingTimeInterval(-r)
                }
            }
        }
        var n = state.terminals.filter { $0.status == .working }.count
        for i in state.terminals.indices where n < working && state.terminals[i].status != .working {
            state.terminals[i].status = .working
            state.terminals[i].runningSince = now.addingTimeInterval(-Double(37 + 113 * n))
            n += 1
        }
    }

    /// The board's own vertical scroll view: the tallest document among the scroll views in the window.
    private static func boardScrollView(in view: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.hasVerticalScroller || (s.documentView?.frame.height ?? 0) > s.frame.height {
                found.append(s)
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.05))) }
    }

    /// Main-thread CPU, in ms, spent inside `body`.
    private static func cpu(_ body: () -> Void) -> Double {
        func now() -> Double {
            var ts = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
            return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
        }
        let t0 = now()
        body()
        return now() - t0
    }

    private static func median(_ xs: [Double]) -> Double { percentile(xs, 0.5) }
    private static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }

    /// Each stretch the main run loop spends awake, from waking to going back to sleep — the time a
    /// frame could not be drawn. One observer first in line on waking, one last before sleeping, so
    /// the commit that SwiftUI and Core Animation do just before sleep falls inside the stretch.
    private final class StallMeter {
        private var woke: CFTimeInterval = 0
        private(set) var stretches: [Double] = []
        private var observers: [CFRunLoopObserver] = []

        init() {
            // Entering the loop counts as waking: `spin` re-enters it after every write and scroll
            // step, and the work those provoke runs before the loop first sleeps.
            let wakes = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.entry.rawValue
            let wake = CFRunLoopObserverCreateWithHandler(nil, wakes, true, CFIndex.min) { [unowned self] _, _ in
                if self.woke == 0 { self.woke = CACurrentMediaTime() }
            }
            let sleeps = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
            let sleep = CFRunLoopObserverCreateWithHandler(nil, sleeps, true, CFIndex.max) { [unowned self] _, _ in
                guard self.woke > 0 else { return }
                self.stretches.append((CACurrentMediaTime() - self.woke) * 1000)
                self.woke = 0
            }
            for o in [wake, sleep].compactMap({ $0 }) {
                CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
                observers.append(o)
            }
        }
        func reset() { stretches.removeAll(); woke = 0 }
        var longest: Double { stretches.max() ?? 0 }
        func count(over ms: Double) -> Int { stretches.filter { $0 > ms }.count }
        /// How many stretches cost one frame or more, two or more, four or more (at 120 Hz), and the longest.
        var summary: String {
            String(format: ">8ms %d, >17ms %d, >33ms %d, longest %.1f ms",
                   count(over: 8.3), count(over: 16.7), count(over: 33.3), longest)
        }
    }
}
