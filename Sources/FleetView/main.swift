import AppKit

// Bare SPM executable → programmatic NSApplication bootstrap (no .xcodeproj / Info.plist needed).
// main.swift top-level runs on the main thread, which hosts the main actor, so we assume that
// isolation to construct our @MainActor app objects.
MainActor.assumeIsolated {
    // No window server (an SSH-only Mac) or `--headless`: serve the board without a window.
    // NSApplication would otherwise sit in its event loop never having finished launching.
    if Headless.wanted { Headless.run() }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
