import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Recovery cost per sport
//
// Shapes sessions and daily Charge into the input `ActivityCostEngine` ranks, and finds the one-sentence
// "sessions like this usually..." pattern for a sport. Used by the post-log note on the Training page and
// by the next-morning line on the workout detail, so both state the same pattern. The engine is pure;
// all the database-to-input shaping lives here.

enum TrainingActivityCost {

    /// The ranked per-sport costs. Sessions and daily metrics are keyed on the LOCAL calendar day
    /// (`DailyMetric.day`'s calendar), which keeps the engine's next-morning lookups aligned.
    static func costs(workouts: [WorkoutRow], days: [DailyMetric]) -> [ActivityCost] {
        let tzOffset = TimeZone.current.secondsFromGMT()
        var activityDaysBySport: [String: Set<String>] = [:]
        for w in workouts {
            let sport = WorkoutSource.displaySport(w.sport)
            guard !sport.isEmpty else { continue }
            activityDaysBySport[sport, default: []].insert(AnalyticsEngine.dayString(w.startTs, offsetSec: tzOffset))
        }
        var recoveryByDay: [String: Double] = [:]
        for d in days {
            if let r = d.recovery { recoveryByDay[d.day] = r }
        }
        return ActivityCostEngine.evaluate(activityDaysBySport: activityDaysBySport, recoveryByDay: recoveryByDay)
    }

    /// The engine's sentence for `sport`, or nil while it has fewer than `ActivityCostEngine.minSessions`
    /// sessions of it.
    static func sentence(forSport sport: String, workouts: [WorkoutRow], days: [DailyMetric]) -> String? {
        let display = WorkoutSource.displaySport(sport)
        return costs(workouts: workouts, days: days).first { $0.sport == display }?.sentence()
    }
}
