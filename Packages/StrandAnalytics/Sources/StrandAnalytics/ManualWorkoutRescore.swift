import Foundation
import WhoopProtocol

/// Re-scores a manual workout's HR-derived metrics (avg/peak HR, strain, calories) from the HR samples now
/// available for its window. A manual workout is scored at save time from sparse live HR (on 5.0/MG calories
/// collapse toward ~1 kcal and strain is empty, #137); once the strap's banked HR is offloaded, this
/// recomputes it. Pure; the caller picks the under-scored `manual` workouts and persists only genuine
/// improvements. Formulas mirror the app's `endWorkout` (`StrainScorer` + `Calories.estimateBoutCalories`).
public enum ManualWorkoutRescore {

    public struct Scored: Equatable {
        public let avgHr: Int
        public let maxHr: Int
        public let strain: Double?
        public let kcal: Double?
        public init(avgHr: Int, maxHr: Int, strain: Double?, kcal: Double?) {
            self.avgHr = avgHr; self.maxHr = maxHr; self.strain = strain; self.kcal = kcal
        }
    }

    /// At/under this many kcal a manual workout looks under-scored (#137).
    public static let underScoredKcalThreshold = 5.0
    /// A rescore must beat the stored calories by this much to persist, keeping the pass idempotent.
    public static let improvementMarginKcal = 1.0

    /// Whether the workout looks under-scored (missing/negligible calories); well-scored workouts are never touched.
    public static func looksUnderScored(currentKcal: Double?) -> Bool {
        (currentKcal ?? 0) <= underScoredKcalThreshold
    }

    /// Recomputes avg/peak HR, strain and calories from `windowSamples`; nil when too few samples to beat what exists.
    /// `restingHR` is the MEASURED resting HR (#950), used for the strain %HRR denominator and the calories
    /// active-vs-resting threshold (resting + 30% HRR) so the workout is scored like its day; nil keeps the default 60.
    public static func scored(windowSamples: [HRSample], profile: UserProfile, hrMax: Double,
                              restingHR: Double? = nil,
                              // #1545: Edwards by default, threaded by the app (see WorkoutDetector.detect).
                              effortMethod: StrainScorer.Method = .edwards) -> Scored? {
        guard windowSamples.count >= 2 else { return nil }
        let bpms = windowSamples.map(\.bpm)
        let avg = Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
        let peak = bpms.max() ?? 0
        let strain = StrainScorer.strain(windowSamples, maxHR: hrMax,
                                         restingHR: restingHR ?? StrainScorer.defaultRestingHR,
                                         method: effortMethod, sex: profile.sex)
        let kcalRaw = Calories.estimateBoutCalories(windowSamples, profile: profile,
                                                    hrmax: hrMax, restingHR: restingHR).0
        return Scored(avgHr: avg, maxHr: peak, strain: strain, kcal: kcalRaw > 0 ? kcalRaw : nil)
    }

    /// Whether `scored` is a worthwhile improvement over the stored row: strictly more energy (keeps the pass
    /// idempotent and unable to lower a workout), or, with `allowStrainOnlyFill`, a strain where the row has none
    /// (merged workouts sum kcal so never look under-scored; the caller keeps the existing kcal).
    public static func improves(_ scored: Scored, over currentKcal: Double?,
                                currentStrain: Double? = nil, allowStrainOnlyFill: Bool = false) -> Bool {
        if let newK = scored.kcal, newK > (currentKcal ?? 0) + improvementMarginKcal { return true }
        return allowStrainOnlyFill && currentStrain == nil && scored.strain != nil
    }
}
