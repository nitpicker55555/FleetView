import Foundation
import SwiftUI

/// A clock the board's labels redraw by: one timer per period for the whole app, firing on whole
/// multiples of the period since `RelativeTime.tickEpoch`, so every label on the same period changes
/// in the same pass.
///
/// Not `TimelineView`, which is what the board's clocks were. A TimelineView is consulted on every
/// update of its window, whether or not its next tick is due — on every frame of a scroll — and the
/// window's clock reaches all of them each frame. A 19-card board has ~60 (a run clock or an age on
/// every card, twice for a running one; two in every project header; one per running row in the
/// sidebar): Instruments counted ~30 timeline checks per frame while scrolling, and the time reaching
/// them was a fifth of the main thread's scrolling work (SnapshotBench, 2026-11-10). A ticker is an
/// ordinary `ObservableObject`, so between its ticks nothing on the board depends on it.
@MainActor
final class Ticker: ObservableObject {
    @Published private(set) var now = Date()
    private var timer: Timer?

    private static var tickers: [TimeInterval: Ticker] = [:]

    /// The ticker for `period` seconds, started the first time anything asks for it.
    static func every(_ period: TimeInterval) -> Ticker {
        if let t = tickers[period] { return t }
        let t = Ticker(period: period)
        tickers[period] = t
        return t
    }

    private init(period: TimeInterval) {
        let epoch = RelativeTime.tickEpoch.timeIntervalSinceReferenceDate
        let elapsed = Date().timeIntervalSinceReferenceDate - epoch
        let first = Date(timeIntervalSinceReferenceDate: epoch + (floor(elapsed / period) + 1) * period)
        // Repeats from its first fire date, not from whenever the last fire ran, so it does not drift
        // off the epoch. Common modes: a clock that stops while the board is being scrolled (the
        // event-tracking mode) would jump when the scroll ends.
        let timer = Timer(fire: first, interval: period, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        timer.tolerance = min(0.05, period / 20)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// `TimelineView(.periodic(…))`'s shape on a `Ticker`: `content` is drawn again on each tick, with
/// the time it is drawn at, and at no other time unless its parent is redrawn.
struct Ticked<Content: View>: View {
    @ObservedObject private var tick: Ticker
    private let content: (Date) -> Content

    init(every period: TimeInterval, @ViewBuilder content: @escaping (Date) -> Content) {
        _tick = ObservedObject(wrappedValue: Ticker.every(period))
        self.content = content
    }

    var body: some View { content(Date()) }
}
