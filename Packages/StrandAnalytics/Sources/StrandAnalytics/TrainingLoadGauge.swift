import Foundation
import WhoopStore

// MARK: - Training-load gauges
//
// Cardio and Muscular load readouts for the Workouts tab. Each compares this week's load with the user's OWN
// recent norm and marks a band (0.8...1.3 x norm) around it. Descriptive only: nothing here feeds Readiness,
// Effort or any score, and the copy never mentions injury. Until `calibrationDays` of history exist the gauge
// says "Calibrating".
//   - Cardio reuses `TrainingLoadEngine`: acute = ATL (7-day), norm = CTL (42-day), in stored Effort units.
//   - Muscular counts WORKING sets (performed, not warm-up): acute = last 7 days, norm = last 28 days / 4.
//     Kilograms are not used because volume is not comparable between exercises (`LiftMetrics.volumeLoadKg`).

public enum TrainingLoadGauge {

    public static let bandLow = 0.8
    public static let bandHigh = 1.3
    /// History needed before a gauge leaves "Calibrating": three weeks.
    public static let calibrationDays = 21
    /// Muscular window: four weeks of sets form the norm.
    public static let chronicWindowDays = 28
    public static let acuteWindowDays = 7

    public enum State: String, Sendable, Equatable {
        case calibrating, low, optimal, high
    }

    public struct Reading: Equatable, Sendable {
        public let state: State
        /// This week's load; nil only when there is nothing to show.
        public let acute: Double?
        /// The user's norm (CTL, or weekly sets over four weeks); nil while calibrating.
        public let chronic: Double?
        public let optimalLow: Double?
        public let optimalHigh: Double?
        /// The gauge's right-hand end: a round number above both the value and the band.
        public let scaleMax: Double
        public init(state: State, acute: Double?, chronic: Double?, optimalLow: Double?,
                    optimalHigh: Double?, scaleMax: Double) {
            self.state = state
            self.acute = acute
            self.chronic = chronic
            self.optimalLow = optimalLow
            self.optimalHigh = optimalHigh
            self.scaleMax = scaleMax
        }
    }

    /// Classifies `acute` against a norm; calibrating when `historyDays` is short.
    public static func reading(acute: Double?, chronic: Double?, historyDays: Int) -> Reading {
        guard historyDays >= calibrationDays, let a = acute, let c = chronic, a.isFinite, c.isFinite else {
            return Reading(state: .calibrating, acute: acute, chronic: nil, optimalLow: nil,
                           optimalHigh: nil, scaleMax: niceCeiling(max(acute ?? 0, 1) * 1.5))
        }
        let low = c * bandLow
        let high = c * bandHigh
        let state: State
        if c <= 0 {
            state = a > 0 ? .high : .low
        } else if a < low {
            state = .low
        } else if a > high {
            state = .high
        } else {
            state = .optimal
        }
        return Reading(state: state, acute: a, chronic: c, optimalLow: low, optimalHigh: high,
                       scaleMax: niceCeiling(max(a * 1.15, high * 1.5, 1)))
    }

    /// Cardio load from the existing training-load model.
    public static func cardio(_ result: TrainingLoadEngine.Result) -> Reading {
        reading(acute: result.acuteLoad, chronic: result.chronicLoad, historyDays: result.contiguousDays)
    }

    /// Cardio load straight from daily Effort rows.
    public static func cardio(days: [TrainingLoadEngine.DailyLoad]) -> Reading {
        cardio(TrainingLoadEngine.evaluate(days: days))
    }

    // MARK: Muscular

    /// One finished lift session; `daysAgo` is whole local days before today (resolved by the caller, so this stays timezone-free).
    public struct LiftDay: Sendable {
        public let daysAgo: Int
        public let sets: [LiftSetRow]
        public init(daysAgo: Int, sets: [LiftSetRow]) {
            self.daysAgo = daysAgo
            self.sets = sets
        }
    }

    /// Working sets in a session: performed and not a warm-up.
    public static func workingSets(_ sets: [LiftSetRow]) -> Int {
        sets.filter { !$0.isWarmup && LiftMetrics.isPerformed(reps: $0.reps) }.count
    }

    /// Muscular load; `historyDays` = days since the first lift session on record, inclusive of today.
    public static func muscular(sessions: [LiftDay], historyDays: Int) -> Reading {
        var acute = 0, chronic = 0
        for s in sessions where s.daysAgo >= 0 {
            let n = workingSets(s.sets)
            if s.daysAgo < acuteWindowDays { acute += n }
            if s.daysAgo < chronicWindowDays { chronic += n }
        }
        let weeks = Double(chronicWindowDays) / Double(acuteWindowDays)
        return reading(acute: Double(acute), chronic: Double(chronic) / weeks, historyDays: historyDays)
    }

    // MARK: Strength week

    public struct StrengthWeek: Equatable, Sendable {
        public let workingSets: Int
        /// Sum of weight x reps over working sets, kg; 0 when nothing countable was logged.
        public let volumeKg: Double
        public init(workingSets: Int, volumeKg: Double) {
            self.workingSets = workingSets
            self.volumeKg = volumeKg
        }
    }

    /// Working sets and volume over the last seven days, today included.
    public static func strengthWeek(sessions: [LiftDay]) -> StrengthWeek {
        let recent = sessions.filter { $0.daysAgo >= 0 && $0.daysAgo < acuteWindowDays }
        let sets = recent.reduce(0) { $0 + workingSets($1.sets) }
        let volume = recent.reduce(0.0) { $0 + (LiftMetrics.volumeLoadKg($1.sets.filter {
            LiftMetrics.isPerformed(reps: $0.reps) }) ?? 0) }
        return StrengthWeek(workingSets: sets, volumeKg: volume)
    }

    // MARK: Helpers

    /// Smallest of 1, 2, 2.5, 5 x 10^n at or above `v`, so the gauge ends on a readable number.
    public static func niceCeiling(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return 1 }
        let mag = pow(10, floor(log10(v)))
        for step in [1.0, 2.0, 2.5, 5.0, 10.0] where step * mag >= v - 1e-9 {
            return step * mag
        }
        return 10 * mag
    }
}
