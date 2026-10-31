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
    @State private var expanded: Set<String> = []
    @State private var notes: [String: String] = [:]
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.badge.clock").font(.system(size: 15)).foregroundColor(Theme.primary)
                    Text(L(.fleetTrigTitle)).font(.fvTitleMedium).foregroundColor(Theme.onSurface)
                    Text("\(state.fleetTriggers.count)").font(.fvLabel).foregroundColor(Theme.onSurfaceVariant)
                }
                Text(L(.fleetTrigSubtitle)).font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        .frame(width: 500)
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

    private func row(_ s: FleetTriggerStatus) -> some View {
        let t = s.trigger
        let open = expanded.contains(t.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(t.when.kind)).font(.system(size: 12)).foregroundColor(Theme.onSurfaceVariant)
                Text(t.name).font(.fvTitleSmall).foregroundColor(Theme.onSurface).lineLimit(1)
                Text(t.id).font(.fvLabelSmall).foregroundColor(Theme.outline).textSelection(.enabled)
                Spacer(minLength: 6)
                status(s)
            }
            Text(schedule(t)).font(.fvLabel).foregroundColor(Theme.onSurfaceVariant)
            Text("$ " + t.run).font(.fvMono).foregroundColor(Theme.onSurface)
                .lineLimit(open ? nil : 2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(Theme.surfaceContainerHighest.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { toggle(t.id) }
            if open, let tail = t.last?.tail {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(.fleetTrigOutput)).font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
                    Text(tail).font(.fvMono).foregroundColor(Theme.onSurfaceVariant).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            source(t)
            HStack(spacing: 8) {
                pill(L(.fleetTrigRunNow), "play.fill", disabled: s.running) {
                    notes[t.id] = FleetTriggerEngine.shared.fire(t.id)
                }
                pill(t.paused == true ? L(.fleetTrigResume) : L(.fleetTrigPause),
                     t.paused == true ? "arrow.clockwise" : "pause.fill") {
                    _ = FleetTriggerEngine.shared.setPaused(t.id, t.paused != true)
                }
                Spacer()
                if confirming == t.id {
                    pill(L(.cancel), "xmark") { confirming = nil }
                    pill(L(.fleetTrigConfirmRemove), "trash.fill", danger: true) {
                        confirming = nil
                        _ = FleetTriggerEngine.shared.remove(t.id)
                    }
                } else {
                    pill(L(.fleetTrigRemove), "trash") { confirming = t.id }
                }
            }
            if let note = notes[t.id] {
                Text(note).font(.fvLabelSmall).foregroundColor(Theme.error)
            }
        }
        .padding(12)
        .background(Theme.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(t.paused == true ? 0.7 : 1)
    }

    /// The card that set it up, by uuid — the thing an agent or `project-manager` addresses it by —
    /// with its name and what has become of it, and the way back to it.
    @ViewBuilder private func source(_ t: FleetTrigger) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(L(.fleetTrigSource)).font(.fvLabelSmall).foregroundColor(Theme.onSurfaceVariant)
            if let src = t.source {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(cardName(t) ?? "—").font(.fvLabel).foregroundColor(Theme.onSurface).lineLimit(1)
                        if let fate = cardFate(src) {
                            Text(fate).font(.fvLabelSmall).foregroundColor(Theme.outline)
                        }
                    }
                    Text(src.lowercased()).font(.fvLabelSmall.monospaced()).foregroundColor(Theme.onSurfaceVariant)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(src.lowercased(), forType: .string)
                    copied = t.id
                } label: {
                    Image(systemName: copied == t.id ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                        .foregroundColor(Theme.onSurfaceVariant)
                }
                .buttonStyle(.plain).help(L(.copy))
                pill(L(.fleetTrigRestore), "arrow.uturn.backward") {
                    let (status, body) = state.restoreFleetTriggerSource(t)
                    notes[t.id] = status.hasPrefix("200") ? nil : (body["error"] as? String ?? status)
                }
            } else {
                Text(L(.fleetTrigNoSource)).font(.fvLabelSmall).foregroundColor(Theme.outline)
                Spacer()
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder private func status(_ s: FleetTriggerStatus) -> some View {
        if s.running {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 11, height: 11)
                Text(L(.fleetTrigRunning)).font(.fvLabel)
            }
            .foregroundColor(Theme.onPrimaryContainer)
            .padding(.horizontal, 10).frame(height: 22)
            .background(Theme.primaryContainer).clipShape(Capsule())
        } else if let last = s.trigger.last {
            let ok = last.exit == 0 && last.note == nil
            let when = Self.short(last.at)
            let text = last.exit.map { ok ? L(.fleetTrigLastOK(when, Self.duration(last.seconds ?? 0)))
                                          : L(.fleetTrigLastFail(when, $0)) } ?? (last.note ?? "?")
            Text(text).font(.fvLabel)
                .foregroundColor(ok ? Theme.onSurfaceVariant : Theme.onErrorContainer)
                .padding(.horizontal, 10).frame(height: 22)
                .background(ok ? Theme.surfaceContainerHighest : Theme.errorContainer).clipShape(Capsule())
                .help(last.note ?? "")
        } else {
            Text(L(.fleetTrigNever)).font(.fvLabel).foregroundColor(Theme.outline)
        }
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

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
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
        case "cron": what = L(.fleetTrigWhenCron(w.cron ?? ""))
        case "every": what = L(.fleetTrigWhenEvery(Self.duration(w.every ?? 0)))
        case "at": what = L(.fleetTrigWhenAt(w.at.map(Self.short) ?? "?"))
        case "watch": what = L(.fleetTrigWhenWatch((w.path ?? "").replacingOccurrences(of: FV.home.path, with: "~")))
        case "check": what = L(.fleetTrigWhenCheck(w.check ?? ""))
        default: what = L(.fleetTrigWhenManual)
        }
        if t.paused == true { return what + " · " + L(.fleetTrigPaused) }
        if let due = t.due { return what + " · " + L(.fleetTrigNext(Self.short(due))) }
        if w.kind == "at", t.last != nil { return what + " · " + L(.fleetTrigDone) }
        return what
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
