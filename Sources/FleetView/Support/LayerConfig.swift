import Foundation

/// How the window's depths look, read from `~/.fleetview/layers.json` if it exists.
///
/// The window has three depths, and every surface belongs to exactly one:
///
/// - **0 — the dashboard.** Sidebar, top bar, the board of terminal cards.
/// - **1 — a panel that takes over the window.** The session tree, conversation search, and the
///   action zones that appear while a terminal card is dragged.
/// - **2 — a detail card floating over a level-1 panel.** A pinned session-tree node, a search
///   result's conversation preview.
///
/// When a depth has something above it, it recedes: blurred and washed with black, by these
/// numbers and no others. They live here because they were previously five different pairs
/// scattered across the views (0.28 with blur, 0.16 without, 0.42, 0.25, 0.001), which is what made
/// the layering read as several unrelated effects rather than one system.
///
/// Dismissal follows the same order in reverse: a click on empty space closes the deepest open
/// layer first, so 2 before 1.
struct LayerConfig: Codable {
    /// Gaussian blur on a layer that has one above it.
    var blur: Double = 3
    /// Black wash over a layer that has one above it.
    var dim: Double = 0.28
    /// How long receding and returning take.
    var duration: Double = 0.2

    static var current: LayerConfig = load()

    static func load() -> LayerConfig {
        let url = FV.supportDir.appendingPathComponent("layers.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(LayerConfig.self, from: data) else {
            return LayerConfig()
        }
        return config
    }
}
