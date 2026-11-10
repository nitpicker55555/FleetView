import AppKit

// Bare SPM executable → programmatic NSApplication bootstrap (no .xcodeproj / Info.plist needed).
// main.swift top-level runs on the main thread, which hosts the main actor, so we assume that
// isolation to construct our @MainActor app objects.
MainActor.assumeIsolated {
    // Before anything reads a preference: settings written under the old bundle id come along.
    LegacyDefaults.migrate()
    // Draw the board with sample data to PNGs and exit — the way to look at a UI change without
    // launching a second FleetView (see Snapshot).
    if let dir = Snapshot.outputDir { Snapshot.run(into: dir) }
    // No window server (an SSH-only Mac) or `--headless`: serve the board without a window.
    // NSApplication would otherwise sit in its event loop never having finished launching.
    if Headless.wanted { Headless.run() }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
