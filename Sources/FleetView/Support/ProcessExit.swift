import Foundation

extension Process {
    /// `run()`, handing back what to call instead of `waitUntilExit()`.
    ///
    /// `waitUntilExit` turns the calling thread's run loop and checks for the exit between turns. On
    /// a main run loop with nothing else to wake it a turn lasts ~70 ms, so a tmux call that finished
    /// in 4 ms held the main thread for 70 — measured on `/state`'s `list-sessions`, every 2 s, once
    /// the board stopped animating and the frames that used to wake the run loop were gone. The
    /// termination handler is called on Foundation's own queue the moment the process exits.
    func runForExit() throws -> () -> Void {
        let exited = DispatchSemaphore(value: 0)
        terminationHandler = { _ in exited.signal() }
        try run()
        return { exited.wait() }
    }
}
