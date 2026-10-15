import Foundation

/// The one pause-aware elapsed calculation for an in-flight workout, shared by every surface that shows its clock.
enum ActiveWorkoutClock {

    /// Seconds of active time: wall time since `start`, minus completed pauses, minus the open one if paused now.
    /// Clamped once at zero on the result (not per term) so a future `pausedAt` behaves the same on both platforms.
    static func activeElapsed(start: Date, pausedAt: Date?, pausedDuration: TimeInterval,
                              now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(start) - pausedDuration
            - (pausedAt.map { now.timeIntervalSince($0) } ?? 0))
    }

    /// `M:SS` up to an hour, `H:MM:SS` after. Negative input clamps to "0:00".
    static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
