import Foundation

/// The ambient "who is acting right now", scoped to the call stack.
///
/// This is the piece that lets the *view layer* stay free of logging code. An entry point declares
/// the actor once — a web request wraps its handler, the hook pipeline wraps its dispatch — and
/// every state change provoked underneath inherits it, however deep. It is the same trick
/// paper_trail uses for `whodunnit` (RequestStore) and django-auditlog for its `actor` (middleware
/// writing thread-local storage); both libraries note that without it the actor is simply null.
///
/// **Why thread-local and not `@TaskLocal`**: `@TaskLocal` only propagates down *structured
/// concurrency* child tasks. FleetView's mutations arrive through synchronous SwiftUI action
/// closures and through `DispatchQueue.main.async { MainActor.assumeIsolated { … } }` in the web
/// server — neither is a child task, so a `@TaskLocal` binding would silently fail to reach them.
/// Scoping to the thread covers both, because in every case the push and the mutation happen on the
/// same (main) thread.
public enum AuditContext {
    private static let key = "ai.eigent.fleetview.audit.context"

    private struct Frame {
        let actor: AuditActor
        let trace: AuditTrace?
    }

    /// Used when nothing has been pushed. The app sets this to `.desktop` at launch, so any UI
    /// action — including one added years from now — is attributed correctly with no extra code.
    public static var fallback = AuditActor(kind: .system)

    private static var stack: [Frame] {
        get { (Thread.current.threadDictionary[key] as? [Frame]) ?? [] }
        set { Thread.current.threadDictionary[key] = newValue }
    }

    public static var actor: AuditActor { stack.last?.actor ?? fallback }
    public static var trace: AuditTrace? { stack.last?.trace }

    /// Run `body` with `actor` (and optionally a trace) as the ambient context.
    /// Nesting is supported: an inner scope shadows an outer one and restores it on exit.
    @discardableResult
    public static func with<T>(_ actor: AuditActor,
                               trace: AuditTrace? = nil,
                               _ body: () throws -> T) rethrows -> T {
        var frames = stack
        frames.append(Frame(actor: actor, trace: trace ?? frames.last?.trace))
        stack = frames
        defer {
            var f = stack
            if !f.isEmpty { f.removeLast() }
            stack = f
        }
        return try body()
    }

    /// Test/teardown helper — drops any frames a failed scope might have left behind.
    public static func reset() {
        Thread.current.threadDictionary[key] = nil
    }
}
