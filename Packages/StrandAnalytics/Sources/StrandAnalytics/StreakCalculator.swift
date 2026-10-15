import Foundation

// StreakCalculator: consecutive-day "streak" over days that carry a qualifying record (#569). Derived purely
// from the set of local calendar days that already have a score; civil-day arithmetic is TZ-free
// (`Baselines.isoEpochDay`). No clock, I/O or PII.

public enum StreakCalculator {

    /// The current and longest consecutive-day runs.
    public struct Streaks: Equatable, Sendable {
        /// The unbroken run of qualifying days ending at `today`, or at `today - 1` when today is not yet
        /// scored (the score lands after that night's sleep, so the streak must not read 0 all day).
        public let current: Int
        /// The longest unbroken run anywhere in the supplied history.
        public let longest: Int
        public init(current: Int, longest: Int) {
            self.current = current
            self.longest = longest
        }
    }

    /// Computes `(current, longest)` from parallel `dayKeys` / `qualified` (`yyyy-MM-dd`) and an ISO `today`.
    /// Duplicate or unparseable keys are ignored, as is the excess of a longer array. `(0, 0)` when nothing qualifies.
    public static func streaks(dayKeys: [String], qualified: [Bool], today: String) -> Streaks {
        // Distinct civil-epoch days that carry a qualifying record.
        var days = Set<Int>()
        for i in 0..<Swift.min(dayKeys.count, qualified.count) where qualified[i] {
            if let e = Baselines.isoEpochDay(dayKeys[i]) { days.insert(e) }
        }
        guard !days.isEmpty else { return Streaks(current: 0, longest: 0) }

        // Longest run: start at each day whose predecessor is absent, then count forward.
        var longest = 0
        for d in days where !days.contains(d - 1) {
            var len = 1
            while days.contains(d + len) { len += 1 }
            if len > longest { longest = len }
        }

        // Current run: anchored at today, or yesterday when today is not yet scored.
        var current = 0
        if let t = Baselines.isoEpochDay(today) {
            let anchor: Int? = days.contains(t) ? t : (days.contains(t - 1) ? t - 1 : nil)
            if let a = anchor {
                current = 1
                while days.contains(a - current) { current += 1 }
            }
        }
        return Streaks(current: current, longest: longest)
    }
}
