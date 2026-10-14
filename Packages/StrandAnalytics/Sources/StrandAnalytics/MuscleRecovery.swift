import Foundation
import WhoopStore

// MARK: - Muscle recovery (Zoop)
//
// An estimate of how recovered each muscle group is from the lifting logged in the Lift Log. It is a
// simple, openly stated model, not a measurement: nothing on the strap reads muscle damage.
//
//   • Each session leaves a muscle a recovery window that grows with the fractional sets it got
//     (`LiftMetrics.muscleCounts`: direct sets 1, indirect 0.5): 30 h plus 6 h per set, clamped to
//     36...72 h. Three sets ≈ 48 h, seven or more = 72 h, matching the 48-72 h range commonly quoted
//     for a trained muscle.
//   • A hard session (mean working RPE 9 or higher) stretches the window by 15 %.
//   • Within its window a session's fatigue falls linearly from 1 to 0. Fatigue from overlapping
//     sessions adds up (capped at 1), so training a muscle again before it recovered reads lower.
//
// Percent recovered = 100 × (1 − fatigue).

public enum MuscleRecovery {

    public static let baseHours = 30.0
    public static let hoursPerSet = 6.0
    public static let minHours = 36.0
    public static let maxHours = 72.0
    public static let hardSessionRpe = 9.0
    public static let hardSessionStretch = 1.15
    /// How far back a session can still matter: the longest possible window.
    public static var lookbackHours: Double { maxHours * hardSessionStretch }

    /// One finished session's sets and when it ended.
    public struct Session: Sendable {
        public let endTs: Int
        public let sets: [LiftSetRow]
        public init(endTs: Int, sets: [LiftSetRow]) {
            self.endTs = endTs
            self.sets = sets
        }
    }

    /// One muscle's state at `now`.
    public struct Entry: Equatable, Sendable {
        public let muscle: LiftMuscle
        /// 0...100.
        public let percentRecovered: Int
        /// Hours until fully recovered, 0 when already recovered.
        public let hoursToFull: Double
        /// Fractional sets this muscle got in the sessions still in its window.
        public let recentSets: Double
        public init(muscle: LiftMuscle, percentRecovered: Int, hoursToFull: Double, recentSets: Double) {
            self.muscle = muscle
            self.percentRecovered = percentRecovered
            self.hoursToFull = hoursToFull
            self.recentSets = recentSets
        }
    }

    /// The recovery window, in hours, for one session's fractional sets on one muscle.
    public static func windowHours(sets: Double, hard: Bool = false) -> Double {
        let raw = Swift.min(maxHours, Swift.max(minHours, baseHours + hoursPerSet * sets))
        return hard ? raw * hardSessionStretch : raw
    }

    /// Per-muscle recovery at `now`, for every muscle a session in `sessions` touched. Sorted least
    /// recovered first, then in the vocabulary's order. Sessions in the future are ignored.
    public static func entries(sessions: [Session], now: Int) -> [Entry] {
        var fatigue: [LiftMuscle: Double] = [:]
        var toFull: [LiftMuscle: Double] = [:]
        var recent: [LiftMuscle: Double] = [:]
        var touched = Set<LiftMuscle>()

        for s in sessions where s.endTs <= now {
            let elapsed = Double(now - s.endTs) / 3600
            let hard = (LiftMetrics.rpeProfile(s.sets).mean ?? 0) >= hardSessionRpe
            for (muscle, sets) in LiftMetrics.muscleCounts(s.sets).fractional where sets > 0 {
                touched.insert(muscle)
                let window = windowHours(sets: sets, hard: hard)
                guard elapsed < window else { continue }
                fatigue[muscle, default: 0] += 1 - elapsed / window
                toFull[muscle] = Swift.max(toFull[muscle] ?? 0, window - elapsed)
                recent[muscle, default: 0] += sets
            }
        }

        let order = Dictionary(uniqueKeysWithValues: LiftMuscle.ordered.enumerated().map { ($1, $0) })
        return touched.map { m in
            let f = Swift.min(1, fatigue[m] ?? 0)
            return Entry(muscle: m,
                         percentRecovered: Int((100 * (1 - f)).rounded(.down)),
                         hoursToFull: toFull[m] ?? 0,
                         recentSets: recent[m] ?? 0)
        }
        .sorted {
            $0.percentRecovered != $1.percentRecovered
                ? $0.percentRecovered < $1.percentRecovered
                : (order[$0.muscle] ?? 0) < (order[$1.muscle] ?? 0)
        }
    }

    /// Filled segments of a 10-segment bar for a percentage (rounded down, so 100 % is the only full bar).
    public static func filledSegments(percent: Int, of segments: Int = 10) -> Int {
        Swift.max(0, Swift.min(segments, percent * segments / 100))
    }
}
