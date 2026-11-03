import SwiftUI
import AppKit

/// What the toolbar's trigger button opens: every trigger FleetView itself runs (FleetTriggerEngine),
/// with the card that set each one up and a way back to it.
///
/// These are not the per-card triggers (TriggersPanel). Those are an agent's own crons and die with
/// its CLI; these belong to no card, which is why the list lives on the toolbar and not on a card.
struct FleetTriggersPopover: View {
    @EnvironmentObject var state: AppState
    /// The row whose remove is waiting for a second click.
    @State private var confirming: String?
    @State private var notes: [String: String] = [:]
    @State private var copied: String?
    /// Each trigger's last few runs, read from its log off the main thread.
    @State private var runs: [String: [FleetTriggerLogRun]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.badge.clock").font(.system(size: 15)).foregroundColor(Theme.primary)
                Text(L(.fleetTrigTitle)).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                Text("\(state.fleetTriggers.count)").font(.fvLabel).foregroundColor(Theme.onSurfaceVariant)
            }
            .help(L(.fleetTrigSubtitle))
            .padding(16)
            Rectangle().fill(Theme.outlineVariant).frame(height: 1)
            if state.fleetTriggers.isEmpty {
                empty.padding(16)
            } else {
                // Once a minute is all "next 09:00" needs; running rows change through the engine.
                TimelineView(.everyMinute) { _ in
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(state.fleetTriggers) { row($0) }
                        }
                        .padding(14)
                    }
                }
            }
        }
        .frame(width: 440)
        .frame(maxHeight: 620)
        .background(Theme.panel)
        .onExitCommand { confirming = nil }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(.fleetTrigEmpty)).font(.fvTitleSmall).foregroundColor(Theme.onSurface)
            Text(L(.fleetTrigEmptyBody)).font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
            Text("project-manager trigger add daily --cron '0 9 * * *' \\\n  --run \"project-manager subagent -p <project> --rm '<prompt>'\"")
                .font(.fvMono).foregroundColor(Theme.onSurface).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceContainerHigh).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Row

    /// Width of the leading column every line of a row puts its mark in, so all their text starts
    /// at one edge: the kind icon, the clock, the card, the last run's dot.
    private static let lead: CGFloat = 16

    /// What it is, when it fires, the card that set it up, how its last run went, and pause /
    /// remove. The command is the title's tooltip and the condition is said in words: a row of shell
    /// read as a wall of code rather than as a list of triggers.
    private func row(_ s: FleetTriggerStatus) -> some View {
        let t = s.trigger
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                mark(Image(systemName: icon(t.when.kind)).font(.system(size: 12)))
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(t.name).font(.fvTitleSmall).foregroundColor(Theme.onSurface).lineLimit(1)
                        .help("$ " + t.run)
                    shortID(t.id, key: "t:" + t.id)
                }
                Spacer(minLength: 6)
                iconButton(t.paused == true ? "play.fill" : "pause.fill",
                           help: t.paused == true ? L(.fleetTrigResume) : L(.fleetTrigPause)) {
                    _ = FleetTriggerEngine.shared.setPaused(t.id, t.paused != true)
                }
                if confirming == t.id {
                    iconButton("trash.fill", help: L(.fleetTrigConfirmRemove), danger: true) {
                        confirming = nil
                        _ = FleetTriggerEngine.shared.remove(t.id)
                    }
                } else {
                    iconButton("trash", help: L(.fleetTrigRemove)) { confirming = t.id }
                }
            }
            HStack(spacing: 8) {
                mark(Image(systemName: "clock").font(.system(size: 11)))
                Text(schedule(t)).font(.fvLabel).foregroundColor(Theme.onSurfaceVariant).lineLimit(1)
                    .help(t.when.kind == "check" ? "$ " + (t.when.check ?? "") : "")
            }
            source(t)
            Rectangle().fill(Theme.outlineVariant.opacity(0.7)).frame(height: 1)
            lastRun(s)
            if let note = notes[t.id] {
                Text(note).font(.fvLabelSmall).foregroundColor(Theme.error).padding(.leading, Self.lead + 8)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(t.paused == true ? 0.7 : 1)
        // Read again whenever a run starts or ends.
        .task(id: "\(t.id)|\(t.last?.at.timeIntervalSince1970 ?? 0)|\(s.running)") {
            let id = t.id
            let found = await Task.detached(priority: .utility) { FleetTriggerLogRun.recent(id, max: 1) }.value
            runs[id] = found
        }
    }

    private func mark<V: View>(_ v: V) -> some View {
        v.foregroundColor(Theme.onSurfaceVariant).frame(width: Self.lead, alignment: .center)
    }

    /// The card that set it up, and the way back to it.
    @ViewBuilder private func source(_ t: FleetTrigger) -> some View {
        if let src = t.source {
            HStack(spacing: 8) {
                mark(Image(systemName: "rectangle.on.rectangle").font(.system(size: 10)))
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(cardName(t) ?? "—").font(.fvLabel).foregroundColor(Theme.onSurface).lineLimit(1)
                    shortID(src, key: "s:" + t.id)
                    if let fate = cardFate(src) {
                        Text(fate).font(.fvLabelSmall).foregroundColor(Theme.outline)
                    }
                }
                Spacer(minLength: 4)
                pill(L(.fleetTrigRestore), "arrow.uturn.backward") {
                    let (status, body) = state.restoreFleetTriggerSource(t)
                    notes[t.id] = status.hasPrefix("200") ? nil : (body["error"] as? String ?? status)
                }
            }
        }
    }

    /// Its last run — from the trigger's log, or from `last` while the log is being read (or is gone).
    @ViewBuilder private func lastRun(_ s: FleetTriggerStatus) -> some View {
        let t = s.trigger
        let r = s.running ? nil : ((runs[t.id] ?? nil)?.first ?? t.last.map(FleetTriggerLogRun.init))
        HStack(spacing: 8) {
            if s.running {
                mark(ProgressView().controlSize(.small).scaleEffect(0.45).frame(width: 10, height: 10))
                Text(L(.fleetTrigRunning)).font(.fvLabel).foregroundColor(Theme.primary)
                Spacer()
            } else if let r {
                mark(Circle().fill(color(r.result)).frame(width: 7, height: 7))
                // always with its date: a run log reads as a record, and "20:46" alone does not say which day
                Text(Self.dated(r.at)).font(.fvLabel.monospacedDigit()).foregroundColor(Theme.onSurface)
                Spacer(minLength: 4)
                Text(result(r)).font(.fvLabel.monospacedDigit())
                    .foregroundColor(r.result == .ok || r.result == .running || r.result == .skipped
                                     ? Theme.onSurfaceVariant : Theme.error)
                    .lineLimit(1)
            } else {
                mark(Circle().strokeBorder(Theme.outline, lineWidth: 1).frame(width: 7, height: 7))
                Text(L(.fleetTrigNever)).font(.fvLabel).foregroundColor(Theme.outline)
                Spacer()
            }
        }
    }

    private func result(_ r: FleetTriggerLogRun) -> String {
        switch r.result {
        case .ok: return L(.fleetTrigOK(Self.duration(r.seconds ?? 0)))
        case .failed: return L(.fleetTrigExit(r.exit ?? -1))
        case .timedOut: return L(.fleetTrigTimedOut)
        case .skipped: return L(.fleetTrigSkipped)
        case .notStarted: return L(.fleetTrigNotStarted)
        case .running: return L(.fleetTrigRunning)
        }
    }

    private func color(_ r: FleetTriggerLogRun.Result) -> Color {
        switch r {
        case .ok: return Theme.primary
        case .running: return Theme.primary.opacity(0.5)
        case .skipped: return Theme.outline
        default: return Theme.error
        }
    }

    /// An id as its first four characters; a click copies all of it.
    private func shortID(_ full: String, key: String) -> some View {
        Text(copied == key ? L(.fleetTrigCopied) : String(full.lowercased().prefix(4)))
            .font(.fvLabelSmall.monospaced()).foregroundColor(Theme.outline)
            .help(L(.fleetTrigCopyID))
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(full.lowercased(), forType: .string)
                copied = key
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == key { copied = nil } }
            }
    }

    // MARK: Pieces

    private func iconButton(_ symbol: String, help: String, danger: Bool = false,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundColor(danger ? Theme.onErrorContainer : Theme.onSurfaceVariant)
                .frame(width: 26, height: 26)
                .background(danger ? Theme.errorContainer : Theme.surfaceContainerHighest).clipShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }

    private func pill(_ title: String, _ symbol: String, disabled: Bool = false, danger: Bool = false,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.fvLabel)
            }
            .foregroundColor(danger ? Theme.onErrorContainer : Theme.onSecondaryContainer)
            .padding(.horizontal, 10).frame(height: 26)
            .background(danger ? Theme.errorContainer : Theme.secondaryContainer).clipShape(Capsule())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "cron", "at": return "calendar.badge.clock"
        case "every": return "repeat"
        case "watch": return "doc.badge.clock"
        case "check": return "checkmark.circle.badge.questionmark"
        default: return "hand.tap"
        }
    }

    private func schedule(_ t: FleetTrigger) -> String {
        let w = t.when
        let what: String
        switch w.kind {
        case "cron": what = Self.describeCron(w.cron ?? "") ?? L(.fleetTrigWhenCron(w.cron ?? ""))
        case "every":
            let sec = Int((w.every ?? 0).rounded())
            what = sec >= 3600 && sec % 3600 == 0 ? L(.fleetTrigEveryHours(sec / 3600))
                : sec >= 60 && sec % 60 == 0 ? L(.fleetTrigEveryMinutes(sec / 60))
                : L(.fleetTrigWhenEvery(Self.duration(w.every ?? 0)))
        case "at": what = L(.fleetTrigWhenAt(w.at.map(Self.short) ?? "?"))
        case "watch": what = L(.fleetTrigOnChange((w.path ?? "").replacingOccurrences(of: FV.home.path, with: "~")))
        case "check": what = L(.fleetTrigOnCheck)
        default: what = L(.fleetTrigWhenManual)
        }
        if t.paused == true { return what + " · " + L(.fleetTrigPaused) }
        if let due = t.due { return what + " · " + L(.fleetTrigNext(Self.dated(due))) }
        if w.kind == "at", t.last != nil { return what + " · " + L(.fleetTrigDone) }
        return what
    }

    /// The common cron shapes said in words — daily, weekly, monthly, every N minutes or hours.
    /// Anything else stays a cron line: a wrong sentence is worse than an exact expression.
    static func describeCron(_ cron: String) -> String? {
        let f = cron.split(separator: " ").map(String.init)
        guard f.count == 5 else { return nil }
        let (mi, h, dom, mon, dow) = (f[0], f[1], f[2], f[3], f[4])
        let step = { (s: String) in s.hasPrefix("*/") ? Int(s.dropFirst(2)) : nil }
        if dom == "*", mon == "*", dow == "*" {
            if h == "*", mi == "*" { return L(.fleetTrigEveryMinutes(1)) }
            if h == "*", let n = step(mi) { return L(.fleetTrigEveryMinutes(n)) }
            if Int(mi) != nil, h == "*" { return L(.fleetTrigEveryHours(1)) }
            if Int(mi) != nil, let n = step(h) { return L(.fleetTrigEveryHours(n)) }
        }
        guard let m = Int(mi), let hh = Int(h), mon == "*" else { return nil }
        let time = String(format: "%02d:%02d", hh, m)
        if dom == "*", dow == "*" { return L(.fleetTrigDaily(time)) }
        if dom == "*", let d = Int(dow) {
            var cal = Calendar(identifier: .gregorian)
            cal.locale = Locale(identifier: Lang.current == .zh ? "zh_CN" : "en_US")
            return L(.fleetTrigWeekly(cal.shortWeekdaySymbols[d % 7], time))
        }
        if dow == "*", let d = Int(dom) { return L(.fleetTrigMonthly(String(d), time)) }
        return nil
    }

    private func cardName(_ t: FleetTrigger) -> String? {
        guard let src = t.source, let id = UUID(uuidString: src) else { return t.sourceName }
        return state.terminals.first { $0.id == id }?.name
            ?? state.terminalArchive.first { $0.id == id }?.name ?? t.sourceName
    }

    private func cardFate(_ src: String) -> String? {
        guard let id = UUID(uuidString: src) else { return nil }
        if state.terminals.contains(where: { $0.id == id }) { return nil }
        return state.terminalArchive.contains { $0.id == id } ? L(.fleetTrigSourceRemoved) : L(.fleetTrigSourceGone)
    }

    static func dated(_ d: Date) -> String {
        d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func short(_ d: Date) -> String {
        Calendar.current.isDateInToday(d)
            ? d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func duration(_ s: Double) -> String {
        let n = Int(s.rounded())
        if n < 60 { return "\(n)s" }
        if n < 3600 { return n % 60 == 0 ? "\(n / 60)m" : "\(n / 60)m\(n % 60)s" }
        if n < 86400 { return n % 3600 == 0 ? "\(n / 3600)h" : "\(n / 3600)h\((n % 3600) / 60)m" }
        return "\(n / 86400)d"
    }
}

/// One run as the trigger's log tells it. The log is the only place that keeps more than the last
/// run: each one starts `=== <time> · <reason> ===` and ends `--- exit N · S s ---` (or timed out, or
/// could not start); a fire that found the last run still going is a header that says "skipped".
struct FleetTriggerLogRun: Equatable, Sendable {
    enum Result: Sendable { case ok, failed, timedOut, skipped, notStarted, running }
    var at: Date
    var reason: String
    var result: Result
    var exit: Int32?
    var seconds: Double?

    init(at: Date, reason: String, result: Result, exit: Int32? = nil, seconds: Double? = nil) {
        self.at = at; self.reason = reason; self.result = result; self.exit = exit; self.seconds = seconds
    }

    init(_ r: FleetTriggerRun) {
        let result: Result = r.note != nil && r.exit == nil ? .notStarted
            : r.exit == nil ? .running : r.exit == 0 ? .ok : .failed
        self.init(at: r.at, reason: r.reason, result: result, exit: r.exit, seconds: r.seconds)
    }

    /// The newest `max` runs, from the end of the log. nil when there is no log to read.
    static func recent(_ id: String, max: Int) -> [FleetTriggerLogRun]? {
        guard let h = try? FileHandle(forReadingFrom: FleetTriggerEngine.logURL(id)) else { return nil }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out: [FleetTriggerLogRun] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("=== "), line.hasSuffix(" ===") {
                let parts = line.dropFirst(4).dropLast(4).components(separatedBy: " · ")
                guard parts.count >= 2, let at = f.date(from: parts[0]) else { continue }
                let skipped = parts.count > 2 && parts[2].hasPrefix("skipped")
                out.append(FleetTriggerLogRun(at: at, reason: parts[1], result: skipped ? .skipped : .running))
            } else if line.hasPrefix("--- "), let i = out.indices.last, out[i].result == .running {
                let body = line.dropFirst(4)
                let secs = body.components(separatedBy: " · ").last.flatMap { Double($0.replacingOccurrences(of: " s ---", with: "")) }
                if body.hasPrefix("exit ") {
                    let code = Int32(body.dropFirst(5).prefix { $0 != " " }) ?? -1
                    out[i].exit = code; out[i].seconds = secs; out[i].result = code == 0 ? .ok : .failed
                } else if body.hasPrefix("timed out") {
                    out[i].seconds = secs; out[i].result = .timedOut
                } else if body.hasPrefix("could not start") {
                    out[i].result = .notStarted
                }
            }
        }
        return Array(out.reversed().prefix(max))
    }
}
