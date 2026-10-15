import Foundation
import WhoopProtocol

/// Wrap-aware step derivation from the strap's cumulative `step_motion_counter@57`, shared by the daily
/// total and windowed totals (a manual workout's `[start, end]`, #398).
///
/// The counter is a CUMULATIVE u16 that wraps at 65536 and climbs for some non-step wrist motion too. On
/// classed WHOOP 5/MG records an increment counts only when the sample is labelled walk (1) or run (2); a
/// wholly unclassed legacy window keeps the counter-only estimate. The caller applies `stepTicksPerStep`.
public enum StepsCounter {
    private static let locomotionActivityClasses: Set<Int> = [1, 2]

    static func hasActivityClasses(_ samples: [StepSample]) -> Bool {
        samples.contains { $0.activityClass != nil }
    }

    static func shouldCountDelta(activityClass: Int?, hasActivityClasses: Bool) -> Bool {
        !hasActivityClasses || activityClass.map(locomotionActivityClasses.contains) == true
    }

    /// Absolute reboot/wrap guard, independent from the per-second plausibility gate below.
    public static let maxStepDelta = 512
    public static let maxTicksPerSecond = 4

    static func isPlausibleDelta(previousTs: Int, currentTs: Int, delta: Int) -> Bool {
        guard delta >= 1, delta < maxStepDelta else { return false }
        let elapsed = currentTs - previousTs
        guard elapsed > 0 else { return false }
        let rateAllowance = elapsed >= maxStepDelta / maxTicksPerSecond
            ? maxStepDelta - 1
            : elapsed * maxTicksPerSecond
        return delta <= rateAllowance
    }

    /// Raw wrap-aware locomotion-tick total across `samples` (sorted by `ts` internally). Nil for fewer than
    /// two samples or no retained movement.
    public static func stepsInWindow(_ samples: [StepSample]) -> Int? {
        let sorted = samples.sorted { $0.ts < $1.ts }
        if sorted.count < 2 { return nil }
        let hasActivityClasses = hasActivityClasses(sorted)
        var total = 0
        for i in 1..<sorted.count {
            let delta = (sorted[i].counter - sorted[i - 1].counter) & 0xFFFF  // wrap-aware u16 increment
            let isLocomotion = shouldCountDelta(
                activityClass: sorted[i].activityClass,
                hasActivityClasses: hasActivityClasses)
            if isLocomotion && isPlausibleDelta(
                previousTs: sorted[i - 1].ts, currentTs: sorted[i].ts, delta: delta) {
                total += delta
            }
        }
        return total > 0 ? total : nil
    }
}
