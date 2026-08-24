import Foundation
import SwiftUI

/// Work that takes minutes, moved out of the way of everything else.
///
/// Cloning a repository and installing an update were each run behind something modal — a sheet
/// that would not dismiss, an alert with no progress in it — and each left the window looking hung
/// for as long as the network took, on a machine whose entire job is watching agents that are still
/// running underneath. They are the same shape of problem (start it, watch it, stop it, carry on
/// meanwhile), so they share one model and one pill rather than each growing a progress bar of its
/// own and drifting.
///
/// A finished job clears itself after a moment; a failed one stays until it is dismissed, because
/// by the time the error arrives the sheet that used to show it is long gone and this row is the
/// only place left to put it.
@MainActor
final class BackgroundJobs: ObservableObject {

    /// A singleton because the two callers reach it from places that hold no `AppState` — the
    /// Check-for-Updates menu item, `SelfUpdate` itself — and threading a reference through them
    /// would buy nothing. There is one board, so there is one list of what it is busy with.
    static let shared = BackgroundJobs()

    enum Kind {
        case clone, update

        var icon: String {
            switch self {
            case .clone:  return "arrow.down.circle"
            case .update: return "sparkles"
            }
        }

        /// What the top-bar pill calls it. English, matching the pills it sits next to ("3 working")
        /// rather than the Chinese of the popover it opens.
        var verb: String {
            switch self {
            case .clone:  return "Cloning"
            case .update: return "Updating"
            }
        }
    }

    struct Job: Identifiable {
        let id = UUID()
        let kind: Kind
        var title: String
        var detail: String
        /// nil while the work cannot say how far along it is — git counting objects on the server,
        /// `ditto` unpacking a zip. A spinner is honest there; a bar parked at 0% is not.
        var fraction: Double?
        var failure: String?
        var done = false
        /// Cleared once the point of no return is past (a downloaded update being verified), which
        /// is what takes the ✕ away rather than leaving it there to be pressed for nothing.
        var cancel: (() -> Void)?
        /// What to offer after a failure. The label is part of it because "重试" for a clone and
        /// "打开发布页" for an update that cannot install itself are not the same offer, and one
        /// generic Retry button would be wrong for whichever of them it was not written for.
        var recoverLabel: String?
        var recover: (() -> Void)?
    }

    @Published private(set) var jobs: [Job] = []

    var running: [Job] { jobs.filter { $0.failure == nil && !$0.done } }
    var failed: [Job] { jobs.filter { $0.failure != nil } }

    /// The bar the pill shows. Indeterminate as soon as any one running job is, because averaging
    /// in a phase that reports nothing would draw a number nobody measured.
    var overall: Double? {
        let known = running.compactMap(\.fraction)
        guard !running.isEmpty, known.count == running.count else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    /// One short line for the pill.
    var pillLabel: String {
        if jobs.count > 1 {
            return "\(jobs.count) tasks"
        }
        guard let job = jobs.first else { return "" }
        if job.failure != nil { return "\(job.kind.verb) failed" }
        if job.done { return "Done" }
        if let f = job.fraction { return "\(job.kind.verb) \(Int(f * 100))%" }
        return "\(job.kind.verb)…"
    }

    @discardableResult
    func start(_ kind: Kind, title: String, detail: String = "") -> UUID {
        let job = Job(kind: kind, title: title, detail: detail, fraction: nil)
        withAnimation(.easeOut(duration: 0.18)) { jobs.append(job) }
        return job.id
    }

    /// Progress and its caption move together, always: a detail line that has run ahead of a stale
    /// percentage (or the other way round) is how a progress display starts lying.
    ///
    /// A phase that reports no percentage — git compressing between two measured phases, a zip
    /// being verified after the download hit 100% — leaves the bar where it was rather than
    /// knocking it back to indeterminate, which would read as the work restarting.
    func progress(_ id: UUID, _ fraction: Double?, _ detail: String) {
        guard let i = index(id) else { return }
        if let fraction { jobs[i].fraction = min(max(fraction, 0), 1) }
        jobs[i].detail = detail
    }

    func setCancel(_ id: UUID, _ cancel: (() -> Void)?) {
        guard let i = index(id) else { return }
        jobs[i].cancel = cancel
    }

    /// Succeeded. The row lingers for a moment so what just happened is visible, then goes — a
    /// standing list of finished work is not what this pill is for.
    func finish(_ id: UUID, _ detail: String? = nil) {
        guard let i = index(id) else { return }
        jobs[i].done = true
        jobs[i].fraction = 1
        jobs[i].cancel = nil
        if let detail { jobs[i].detail = detail }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.remove(id) }
    }

    func fail(_ id: UUID, _ why: String, recoverLabel: String? = nil, recover: (() -> Void)? = nil) {
        guard let i = index(id) else { return }
        let text = why.trimmingCharacters(in: .whitespacesAndNewlines)
        jobs[i].failure = text.isEmpty ? "失败，没有更多信息。" : text
        jobs[i].cancel = nil
        jobs[i].recoverLabel = recoverLabel
        jobs[i].recover = recover
    }

    /// Stop it. The row goes at once rather than turning into a "cancelled" one: the user pressed
    /// the button, so reporting back what they just did is noise, and a row that lingers looks like
    /// the work lingered too.
    func cancel(_ id: UUID) {
        guard let i = index(id) else { return }
        let stop = jobs[i].cancel
        remove(id)
        stop?()
    }

    func dismiss(_ id: UUID) { remove(id) }

    private func remove(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.18)) { jobs.removeAll { $0.id == id } }
    }

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }
}
