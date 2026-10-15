import Foundation

/// Descriptive primary-sleep vs wake HR contrast.
///
/// Not a resting-heart-rate definition; it leaves the scoring RHR untouched. Wellness context only: it
/// emits no dipper / non-dipper / riser label, cardiovascular-risk category or diagnostic threshold,
/// since those do not transfer from blood-pressure physiology to wearable HR. Window selection is the
/// caller's responsibility.
public enum SleepHeartRateContrast {
    public static let validMinBpm: Double = 30
    public static let validMaxBpm: Double = 220
    public static let defaultMinimumValidSamples: Int = 30

    public struct Result: Equatable, Sendable {
        /// Mean across valid fixed-grid wake epochs.
        public let wakeMeanBpm: Double
        /// Mean across valid fixed-grid primary-sleep epochs.
        public let sleepMeanBpm: Double
        /// `sleepMeanBpm - wakeMeanBpm`. Negative means HR is lower during sleep.
        public let sleepMinusWakeBpm: Double
        /// `100 * (wakeMeanBpm - sleepMeanBpm) / wakeMeanBpm`. Positive means lower HR during sleep.
        public let sleepReductionPercent: Double

        public let wakeValidSamples: Int
        public let wakeTotalSamples: Int
        public let wakeCoverage: Double
        public let sleepValidSamples: Int
        public let sleepTotalSamples: Int
        public let sleepCoverage: Double

        public init(wakeMeanBpm: Double, sleepMeanBpm: Double, sleepMinusWakeBpm: Double,
                    sleepReductionPercent: Double, wakeValidSamples: Int, wakeTotalSamples: Int,
                    wakeCoverage: Double, sleepValidSamples: Int, sleepTotalSamples: Int,
                    sleepCoverage: Double) {
            self.wakeMeanBpm = wakeMeanBpm
            self.sleepMeanBpm = sleepMeanBpm
            self.sleepMinusWakeBpm = sleepMinusWakeBpm
            self.sleepReductionPercent = sleepReductionPercent
            self.wakeValidSamples = wakeValidSamples
            self.wakeTotalSamples = wakeTotalSamples
            self.wakeCoverage = wakeCoverage
            self.sleepValidSamples = sleepValidSamples
            self.sleepTotalSamples = sleepTotalSamples
            self.sleepCoverage = sleepCoverage
        }
    }

    /// Compare fixed-grid wake and primary-sleep HR windows, or nil when either side lacks coverage.
    ///
    /// Each array holds equal-duration epochs; `nil` is an unobserved epoch, so valid/total is a real
    /// coverage fraction. Values outside `30...220` bpm count as unobserved and are never imputed. The
    /// unweighted mean equals a time-weighted one only because the grid is fixed; aggregate irregular raw
    /// samples onto a declared cadence first.
    ///
    /// `minimumValidSamples` applies per window; its default is a provisional floor, not a clinically
    /// validated threshold.
    public static func evaluate(wakeHR: [Double?], primarySleepHR: [Double?],
                                minimumValidSamples: Int = defaultMinimumValidSamples) -> Result? {
        guard minimumValidSamples > 0, !wakeHR.isEmpty, !primarySleepHR.isEmpty else { return nil }

        let wake = summarize(wakeHR)
        let sleep = summarize(primarySleepHR)
        guard wake.validCount >= minimumValidSamples,
              sleep.validCount >= minimumValidSamples,
              wake.mean > 0 else { return nil }

        let delta = sleep.mean - wake.mean
        let reduction = 100.0 * (wake.mean - sleep.mean) / wake.mean
        guard delta.isFinite, reduction.isFinite else { return nil }

        return Result(
            wakeMeanBpm: wake.mean,
            sleepMeanBpm: sleep.mean,
            sleepMinusWakeBpm: delta,
            sleepReductionPercent: reduction,
            wakeValidSamples: wake.validCount,
            wakeTotalSamples: wakeHR.count,
            wakeCoverage: Double(wake.validCount) / Double(wakeHR.count),
            sleepValidSamples: sleep.validCount,
            sleepTotalSamples: primarySleepHR.count,
            sleepCoverage: Double(sleep.validCount) / Double(primarySleepHR.count)
        )
    }

    private struct Summary {
        let mean: Double
        let validCount: Int
    }

    private static func summarize(_ values: [Double?]) -> Summary {
        var sum = 0.0
        var count = 0
        for item in values {
            guard let value = item, value.isFinite,
                  value >= validMinBpm, value <= validMaxBpm else { continue }
            sum += value
            count += 1
        }
        return Summary(mean: count > 0 ? sum / Double(count) : 0, validCount: count)
    }
}
