import Foundation
import SwiftUI

/// Drives the search panel: debounced querying, grouping, and the index's own progress.
///
/// Hits arrive ranked but flat, and flat is unreadable here — `看看进度` alone appears 292 times
/// across 52 sessions. So results are grouped by transcript, which is also the unit you actually
/// want: "which conversation was that in".
@MainActor
final class SearchModel: ObservableObject {

    /// Every hit that landed in one transcript, newest-ranked first.
    struct Group: Identifiable {
        let id: String                  // transcript path — one file is one session
        let src: SearchIndex.Source
        let project: String
        let session: String
        let when: String
        var hits: [SearchIndex.Hit]
    }

    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var scope: SearchIndex.Scope = .both { didSet { runSearch() } }
    @Published var source: SearchIndex.Source? { didSet { runSearch() } }

    @Published private(set) var groups: [Group] = []
    @Published private(set) var total = 0
    @Published private(set) var elapsed: Double = 0     // ms
    @Published private(set) var truncated = false

    @Published private(set) var indexing = false
    @Published private(set) var indexNote = ""
    @Published private(set) var stats: (messages: Int, files: Int) = (0, 0)

    /// The hit currently being opened — resolving a fork can take a moment, and a click with no
    /// feedback reads as a dead button.
    @Published var opening: Int64?
    @Published var failure: String?

    private var pending: DispatchWorkItem?
    private let limit = 300

    // MARK: - Index

    /// Refresh the index, then re-run whatever is in the box. Cheap when nothing changed (~40 ms).
    func refreshIndex() {
        guard !indexing else { return }
        indexing = true
        indexNote = stats.messages == 0 ? "建立索引…" : "更新索引…"
        SearchIndex.refresh(progress: { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                self.indexNote = "索引 \(p.files)/\(p.total) · \(p.messages) 条"
            }
        }, done: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.indexing = false
                self.indexNote = ""
                self.stats = SearchIndex.stats()
                self.runSearch()
            }
        })
    }

    // MARK: - Query

    private func scheduleSearch() {
        pending?.cancel()
        // Queries land in single-digit milliseconds, so this is only to keep a fast typist from
        // re-rendering the list on every keystroke.
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            groups = []; total = 0; elapsed = 0; truncated = false
            return
        }
        let scope = self.scope, source = self.source, limit = self.limit
        let started = Date()
        // Off the main actor: SQLite is fast here, but the panel must not hitch while typing.
        Task.detached(priority: .userInitiated) {
            let hits = SearchIndex.search(q, scope: scope, limit: limit, source: source)
            let grouped = Self.group(hits)
            let ms = Date().timeIntervalSince(started) * 1000
            await MainActor.run { [weak self] in
                guard let self, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == q
                else { return }                      // a newer keystroke already won
                self.groups = grouped
                self.total = hits.count
                self.truncated = hits.count >= limit
                self.elapsed = ms
            }
        }
    }

    /// Bucket by transcript, preserving BM25 order: the first time a file appears decides where
    /// its group sits, so the best match still floats to the top.
    nonisolated private static func group(_ hits: [SearchIndex.Hit]) -> [Group] {
        var order: [String] = []
        var byPath: [String: Group] = [:]
        for h in hits {
            if var g = byPath[h.path] {
                g.hits.append(h)
                byPath[h.path] = g
            } else {
                order.append(h.path)
                byPath[h.path] = Group(id: h.path, src: h.src,
                                       project: h.project.isEmpty ? "—" : h.project,
                                       session: h.session, when: h.ts, hits: [h])
            }
        }
        return order.compactMap { byPath[$0] }
    }

    // MARK: - Preview

    /// A hit with the conversation around it. Reading costs nothing; only opening writes.
    struct Preview: Identifiable {
        let id: Int64
        let hit: SearchIndex.Hit
        let context: [SearchIndex.Hit]
    }

    @Published var preview: Preview?

    /// Clicking a result reads it — it does NOT resume it. Measured on this corpus, only 3% of
    /// nodes are natively resumable, so opening every result you glance at would write a ~10 MB
    /// fork each time. Reading comes from the index, so browsing stays free and forking becomes a
    /// deliberate second step.
    func showPreview(_ hit: SearchIndex.Hit) {
        let current = preview
        Task.detached(priority: .userInitiated) {
            let context = SearchIndex.context(around: hit)
            await MainActor.run { [weak self] in
                guard let self, current?.id == self.preview?.id else { return }
                self.preview = Preview(id: hit.id, hit: hit, context: context)
            }
        }
    }

    func closePreview() { preview = nil }

    // MARK: - Open

    /// Resolve a hit into a resumed terminal. Runs the fork off the main actor — synthesising a
    /// long chain takes hundreds of milliseconds, and for a big Codex rollout several seconds.
    func open(_ hit: SearchIndex.Hit, in state: AppState, joinClusterOf card: UUID? = nil) {
        guard opening == nil else { return }
        opening = hit.id
        failure = nil
        Task.detached(priority: .userInitiated) {
            do {
                let plan = try SearchOpen.plan(for: hit)
                await MainActor.run {
                    self.preview = nil
                    state.openSearchPlan(plan, joinClusterOf: card)
                    self.opening = nil
                }
            } catch {
                await MainActor.run {
                    self.failure = error.localizedDescription
                    self.opening = nil
                    FV.log("search open failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
