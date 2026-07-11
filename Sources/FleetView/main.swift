import AppKit

// Bare SPM executable → programmatic NSApplication bootstrap (no .xcodeproj / Info.plist needed).
// main.swift top-level runs on the main thread, which hosts the main actor, so we assume that
// isolation to construct our @MainActor app objects.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
