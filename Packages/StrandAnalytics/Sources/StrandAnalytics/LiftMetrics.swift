import Foundation
import WhoopStore

// Training metrics for the Lift Log. Every figure is arithmetic the user can redo by hand from their own sets:
// a few honest numbers rather than one invented score. Pure (no store, clock or UI).
//
// Deliberately absent, and must stay so:
//  - Anything feeding `workout.strain` or daily Effort. Zoop's strain is HR-measured (Karvonen %HRR -> Edwards
//    TRIMP); there is no validated public path from typed sets/reps/weight to cardiovascular strain (cf. the
//    withdrawn PPG->HR estimate, #194).
//  - Per-exercise muscle weightings ("bench press = 0.7 triceps"): no published table exists. The
//    direct/indirect split is what the evidence supports.
//  - Acute:chronic workload ratios or injury-risk / overtraining warnings: validity is disputed.

public enum LiftMetrics {

    // MARK: - Performed or not

    /// Whether a set was performed, from its rep count. Zero reps means not performed (a discarded or skipped
    /// set Edit sets can still fill in); every figure leaves it out. A nil rep count still counts as done.
    /// `WhoopStore.liftSetCounts` and `lastLiftSets` apply the same rule in SQL.
    public static func isPerformed(reps: Int?) -> Bool {
        reps != 0
    }

    // MARK: - Volume load (tonnage)

    /// Sum of weight x reps over working sets, in kg; nil when nothing countable was logged. Warm-ups are
    /// excluded and a set missing weight or reps contributes nothing. Compare progression within one exercise only.
    public static func volumeLoadKg(_ sets: [LiftSetRow]) -> Double? {
        let total = sets.reduce(into: 0.0) { sum, s in
            guard !s.isWarmup, let w = s.weightKg, let r = s.reps, w > 0, r > 0 else { return }
            sum += w * Double(r)
        }
        return total > 0 ? total : nil
    }

    // MARK: - Session load (Foster sRPE-TL)

    /// Session RPE x duration in minutes (Foster's session-RPE load), the one figure that puts resistance and
    /// endurance sessions on one scale. Nil when unrated; a skipped rating is never an effortless 0.
    public static func sessionLoad(sessionRpe: Double?, durationSec: Int) -> Double? {
        guard let rpe = sessionRpe, rpe > 0, durationSec > 0 else { return nil }
        return rpe * (Double(durationSec) / 60.0)
    }

    // MARK: - Estimated one-rep max (Epley)

    /// Rep ceiling above which a 1RM estimate is not shown (the formulas are straight-line fits whose error grows with reps).
    public static let oneRepMaxRepCeiling = 12

    /// Epley: `w x (1 + reps/30)`; nil for a set that can't support an estimate. One rep returns the weight itself
    /// (the formula's +3.3% there is a fit artefact).
    public static func estimatedOneRepMaxKg(weightKg: Double?, reps: Int?) -> Double? {
        guard let w = weightKg, let r = reps, w > 0, r > 0, r <= oneRepMaxRepCeiling else { return nil }
        guard r > 1 else { return w }
        return w * (1.0 + Double(r) / 30.0)
    }

    // MARK: - Per-exercise summary

    public struct ExerciseSummary: Equatable {
        public let exercise: String
        /// Working sets only.
        public let workingSets: Int
        public let warmupSets: Int
        public let volumeKg: Double?
        /// Best set ranked by estimated 1RM, not raw weight (90 kg x 10 beats 100 kg x 5); heaviest set when none supports an estimate.
        public let bestWeightKg: Double?
        public let bestReps: Int?
        public let bestEstimatedOneRepMaxKg: Double?

        public init(exercise: String, workingSets: Int, warmupSets: Int, volumeKg: Double?,
                    bestWeightKg: Double?, bestReps: Int?, bestEstimatedOneRepMaxKg: Double?) {
            self.exercise = exercise
            self.workingSets = workingSets
            self.warmupSets = warmupSets
            self.volumeKg = volumeKg
            self.bestWeightKg = bestWeightKg
            self.bestReps = bestReps
            self.bestEstimatedOneRepMaxKg = bestEstimatedOneRepMaxKg
        }
    }

    /// One summary per exercise in first-performed order. Unperformed sets (`isPerformed`) appear nowhere.
    public static func perExercise(_ sets: [LiftSetRow]) -> [ExerciseSummary] {
        var order: [String] = []
        var grouped: [String: [LiftSetRow]] = [:]
        for s in sets.sorted(by: { $0.ord < $1.ord }) where isPerformed(reps: s.reps) {
            if grouped[s.exercise] == nil { order.append(s.exercise) }
            grouped[s.exercise, default: []].append(s)
        }
        return order.map { name in
            let rows = grouped[name] ?? []
            let working = rows.filter { !$0.isWarmup }

            // Rank by estimated 1RM; otherwise raw weight, so a high-rep-only exercise still reports a best set.
            let best = working.max { a, b in
                let ea = estimatedOneRepMaxKg(weightKg: a.weightKg, reps: a.reps)
                let eb = estimatedOneRepMaxKg(weightKg: b.weightKg, reps: b.reps)
                if let ea, let eb { return ea < eb }
                if ea != nil { return false }
                if eb != nil { return true }
                return (a.weightKg ?? 0) < (b.weightKg ?? 0)
            }
            return ExerciseSummary(
                exercise: name,
                workingSets: working.count,
                warmupSets: rows.count - working.count,
                volumeKg: volumeLoadKg(rows),
                bestWeightKg: best?.weightKg,
                bestReps: best?.reps,
                bestEstimatedOneRepMaxKg: estimatedOneRepMaxKg(weightKg: best?.weightKg,
                                                               reps: best?.reps))
        }
    }

    // MARK: - RPE profile

    public struct RpeProfile: Equatable {
        public let mean: Double?
        public let ratedSets: Int
        public let unratedSets: Int
        public let setsAtOrAboveThreshold: Int
        public let threshold: Double

        public init(mean: Double?, ratedSets: Int, unratedSets: Int,
                    setsAtOrAboveThreshold: Int, threshold: Double) {
            self.mean = mean
            self.ratedSets = ratedSets
            self.unratedSets = unratedSets
            self.setsAtOrAboveThreshold = setsAtOrAboveThreshold
            self.threshold = threshold
        }
    }

    /// Default "close to failure" RPE line; informational only.
    public static let hardSetRpeThreshold = 8.0

    /// How close to failure the working sets were. Reported separately and never used to filter set counts, which
    /// would shift the scale against reference doses built on unfiltered counts. `unratedSets` shows how thin the mean is.
    public static func rpeProfile(_ sets: [LiftSetRow],
                                  threshold: Double = hardSetRpeThreshold) -> RpeProfile {
        let working = sets.filter { !$0.isWarmup && isPerformed(reps: $0.reps) }
        let rated = working.compactMap(\.rpe)
        let mean = rated.isEmpty ? nil : rated.reduce(0, +) / Double(rated.count)
        return RpeProfile(mean: mean,
                          ratedSets: rated.count,
                          unratedSets: working.count - rated.count,
                          setsAtOrAboveThreshold: rated.filter { $0 >= threshold }.count,
                          threshold: threshold)
    }

    // MARK: - Sets per muscle

    public struct MuscleCounts: Equatable {
        /// direct x 1.0 + indirect x 0.5.
        public let fractional: [LiftMuscle: Double]
        public let direct: [LiftMuscle: Int]
        public let indirect: [LiftMuscle: Int]

        public init(fractional: [LiftMuscle: Double], direct: [LiftMuscle: Int],
                    indirect: [LiftMuscle: Int]) {
            self.fractional = fractional
            self.direct = direct
            self.indirect = indirect
        }
    }

    /// Fractional set counts per muscle. The 0.5 indirect credit follows the 2025 Sports Medicine dose-response
    /// meta-regression (fractional had the strongest evidence), the same operationalisation `ReferenceDose` was
    /// derived under, so the two must change together. Warm-ups and unperformed sets are excluded; an unclassified
    /// exercise (nil primary) claims no muscle.
    public static func muscleCounts(_ sets: [LiftSetRow]) -> MuscleCounts {
        var fractional: [LiftMuscle: Double] = [:]
        var direct: [LiftMuscle: Int] = [:]
        var indirect: [LiftMuscle: Int] = [:]
        for s in sets where !s.isWarmup && isPerformed(reps: s.reps) {
            if let p = s.primaryMuscle {
                direct[p, default: 0] += 1
                fractional[p, default: 0] += LiftMuscle.directSetCredit
            }
            for m in s.secondaryMuscles where m != s.primaryMuscle {
                indirect[m, default: 0] += 1
                fractional[m, default: 0] += LiftMuscle.indirectSetCredit
            }
        }
        return MuscleCounts(fractional: fractional, direct: direct, indirect: indirect)
    }

    // MARK: - The reference band

    /// Weekly fractional sets per muscle from the same meta-regression. Shown as a band with its source named,
    /// never as a personal prescription.
    public enum ReferenceDose {
        /// Below roughly this, hypertrophy is not reliably detectable.
        public static let hypertrophyMinimumSetsPerWeek = 4.0
        /// Strength keeps improving from a single weekly set.
        public static let strengthMinimumSetsPerWeek = 1.0
        /// Beyond roughly this, extra volume stops reliably beating the smallest detectable effect for strength; hypertrophy has no identified ceiling.
        public static let strengthPlateauSetsPerWeek = 4.0
    }
}
