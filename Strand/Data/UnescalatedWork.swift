import Foundation

/// Runs `work` off the caller's executor at `priority`, without the awaiting caller dragging it back up.
///
/// Awaiting a `Task.detached(priority: .utility)` from the main actor records a dependency and the
/// runtime escalates the task to the waiter's priority, so the work competes with the UI at the UI's own
/// quality of service. Awaiting a CONTINUATION records no dependency, so the declared priority stands.
///
/// Use this ONLY where EVERY caller is unprompted. Work the wearer started and is watching should
/// escalate. Judge that at the entry point, not at the block that burns the CPU: `analyzeRecent` is
/// reached from a background tick AND from a just-logged workout the wearer is waiting on.
///
/// Cancellation matches a detached task (none inherited); the continuation is resumed exactly once.
func runUnescalated<T: Sendable>(
    priority: TaskPriority = .utility,
    _ work: @escaping @Sendable () async -> T
) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        Task.detached(priority: priority) { continuation.resume(returning: await work()) }
    }
}
