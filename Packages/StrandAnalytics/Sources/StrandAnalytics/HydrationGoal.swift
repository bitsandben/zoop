import Foundation

// Pure daily hydration goal for the opt-in Hydration tracker: a guide, never medical advice.
//
//   GOAL(ml) = roundToNearest(sexBaseline + effortBump, 50)
//     sexBaseline : male 3700, female 2700, unspecified/other 3200 ml
//     effortBump  : clamp(round(effort/100 * 700), 0...700); 0 when no Effort is available
//
// `effort` is the day's strain on the native 0...100 scale (`DailyMetric.strain`).
public enum HydrationGoal {

    // MARK: - Constants

    /// Baseline target by sex (ml), before the Effort bump.
    public static let baselineMaleML = 3700
    public static let baselineFemaleML = 2700
    /// Used for unspecified / other / unrecognised sex tokens.
    public static let baselineOtherML = 3200

    /// Largest Effort bump (ml), reached at Effort 100.
    public static let maxEffortBumpML = 700

    /// The goal is rounded to the nearest multiple of this (ml).
    public static let roundToML = 50

    // MARK: - Quick-log amounts (ml) — the three tap sizes

    public static let sipML = 30
    public static let cupML = 237     // a US cup (8 fl oz)
    public static let bottleML = 500  // a standard small water bottle

    // MARK: - Pieces

    /// Baseline ml for a sex token (case/whitespace-insensitive "male"/"m", "female"/"f"); anything else gets
    /// the unspecified baseline.
    public static func baselineForSex(_ sex: String) -> Int {
        switch sex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "male", "m":   return baselineMaleML
        case "female", "f": return baselineFemaleML
        default:            return baselineOtherML
        }
    }

    /// Effort bump (ml): `round(effort/100 * 700)` clamped to 0...700 after rounding. Nil or non-finite effort yields 0.
    public static func effortBump(effort: Double?) -> Int {
        guard let effort, effort.isFinite else { return 0 }
        let raw = Int((effort / 100.0 * Double(maxEffortBumpML)).rounded())
        return min(maxEffortBumpML, max(0, raw))
    }

    /// Rounds to the nearest multiple of `step` (> 0); halves round up.
    public static func roundToNearest(_ value: Int, step: Int) -> Int {
        guard step > 0 else { return value }
        return ((value + step / 2) / step) * step
    }

    // MARK: - The goal

    /// The day's hydration goal in ml, always a multiple of 50.
    public static func dailyGoalML(sex: String, effort: Double?) -> Int {
        roundToNearest(baselineForSex(sex) + effortBump(effort: effort), step: roundToML)
    }

    // MARK: - Display helpers

    public static func litres(fromML ml: Double) -> Double { ml / 1000.0 }

    /// "<total> / <goal> L" to 1 dp, fixed-locale so the string is stable across platforms.
    public static func cardValueString(totalML: Double, goalML: Int) -> String {
        String(format: "%.1f / %.1f L", litres(fromML: totalML), litres(fromML: Double(goalML)))
    }

    /// Fraction of the goal met (0...1, clamped).
    public static func fraction(totalML: Double, goalML: Int) -> Double {
        guard goalML > 0 else { return 0 }
        return min(1.0, max(0.0, totalML / Double(goalML)))
    }
}
