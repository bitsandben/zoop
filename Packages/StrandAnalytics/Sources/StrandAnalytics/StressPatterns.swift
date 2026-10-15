import Foundation

// Stress patterns for the Stress screen: the typical day (stress by hour) and the week (workdays
// against the weekend). Both are locale-free and return nil when the data cannot carry the reading.
// - timeOfDay: the per-hour means behind `BodyInsights.stressTiming`, with the timing attached only
//   when that reading speaks, so the curve never names a peak the Insights tab would not.
// - week: the daily stress level per ISO weekday, and Mon–Fri against Sat–Sun with a Welch test; a
//   small or noisy gap is reported as no clear difference, not hidden.

public enum StressPatterns {

    // MARK: - Time of day

    public struct TimeOfDay: Equatable, Sendable {
        /// Mean level per hour (only hours seen on enough days), ascending by hour.
        public let hours: [BodyInsights.HourLevel]
        /// Days that carried enough scored hours.
        public let days: Int
        /// Mean of the hour means: the reference line of the curve.
        public let dayMean: Double
        /// The peak and calmest hour, present only when `BodyInsights.stressTiming` finds a clear pattern.
        public let timing: BodyInsights.StressTiming?
    }

    /// The typical stress curve over `days` (one array of hourly levels per day). Nil with fewer than
    /// `BodyInsights.minStressDays` usable days or fewer than six hours seen on enough days.
    public static func timeOfDay(days: [[BodyInsights.HourLevel]]) -> TimeOfDay? {
        let (usable, means) = hourMeans(days)
        guard usable.count >= BodyInsights.minStressDays,
              means.count >= BodyInsights.minScoredHoursPerDay else { return nil }
        let hours = means.keys.sorted().map { BodyInsights.HourLevel(hour: $0, level: means[$0]!) }
        return TimeOfDay(hours: hours, days: usable.count,
                         dayMean: BodyInsights.mean(hours.map(\.level)),
                         timing: BodyInsights.stressTiming(days: days))
    }

    /// The days with at least six scored hours, and the mean level of each hour seen on at least four of
    /// them. Shared by `timeOfDay` and `BodyInsights.stressTiming` so the two cannot disagree.
    static func hourMeans(_ days: [[BodyInsights.HourLevel]]) -> (usable: [[BodyInsights.HourLevel]], means: [Int: Double]) {
        let usable = days.filter { Set($0.map(\.hour)).count >= BodyInsights.minScoredHoursPerDay }
        var byHour: [Int: [Double]] = [:]
        for d in usable {
            for h in d where (0...23).contains(h.hour) && h.level.isFinite {
                byHour[h.hour, default: []].append(h.level)
            }
        }
        let means = byHour.filter { $0.value.count >= BodyInsights.minDaysPerHour }.mapValues(BodyInsights.mean)
        return (usable, means)
    }

    // MARK: - Week

    public struct WeekdayLevel: Equatable, Sendable {
        /// ISO weekday, 1 = Monday … 7 = Sunday.
        public let weekday: Int
        public let mean: Double
        public let days: Int
    }

    public enum WeekendVerdict: String, Equatable, Sendable {
        case weekendCalmer
        case weekendMoreStressed
        case noClearDifference
    }

    public struct Week: Equatable, Sendable {
        /// Weekdays with at least `minPerWeekday` days, ascending (Monday first).
        public let weekdays: [WeekdayLevel]
        public let workdayMean: Double
        public let workdayDays: Int
        public let weekendMean: Double
        public let weekendDays: Int
        /// Two-sided Welch p-value of weekend against workdays.
        public let pValue: Double
        public let verdict: WeekendVerdict
        /// Weekend minus workdays on the 0–3 scale.
        public var difference: Double { weekendMean - workdayMean }
    }

    /// Days looked back from the newest value (or `asOf`): eight weeks, so each weekday can carry a mean.
    public static let weekWindowDays = 56
    public static let minWeekendDays = 4
    public static let minWorkdayDays = 8
    public static let minPerWeekday = 3
    /// A weekend gap below this (0–3 scale) is no clear difference, however small its p-value.
    public static let minWeekendGap = 0.25
    public static let maxWeekendP = 0.05

    /// Daily stress levels (0–3, one per local day) by weekday and Mon–Fri against Sat–Sun. Nil with
    /// fewer than 8 workdays or 4 weekend days in the last 56 days.
    public static func week(_ levels: [BodyInsights.DayValue], asOf: String? = nil) -> Week? {
        let byDay = BodyInsights.dayMap(levels)
        guard let newest = byDay.keys.max() else { return nil }
        let end = asOf.flatMap(BodyInsights.dayNumber) ?? newest
        let window = byDay.filter { $0.key > end - weekWindowDays && $0.key <= end }
        var groups: [Int: [Double]] = [:]
        for (d, v) in window { groups[BodyInsights.isoWeekday(d), default: []].append(v) }
        let work = (1...5).flatMap { groups[$0] ?? [] }
        let weekend = (6...7).flatMap { groups[$0] ?? [] }
        guard work.count >= minWorkdayDays, weekend.count >= minWeekendDays else { return nil }

        let wm = BodyInsights.mean(work), em = BodyInsights.mean(weekend)
        let sw = BodyInsights.sd(work), se = BodyInsights.sd(weekend)
        let p = BehaviorInsights.welchP(m1: em, v1: se * se, n1: weekend.count,
                                        m2: wm, v2: sw * sw, n2: work.count)
        let verdict: WeekendVerdict
        if p < maxWeekendP && abs(em - wm) >= minWeekendGap {
            verdict = em < wm ? .weekendCalmer : .weekendMoreStressed
        } else {
            verdict = .noClearDifference
        }
        let weekdays = (1...7).compactMap { wd -> WeekdayLevel? in
            guard let v = groups[wd], v.count >= minPerWeekday else { return nil }
            return WeekdayLevel(weekday: wd, mean: BodyInsights.mean(v), days: v.count)
        }
        return Week(weekdays: weekdays, workdayMean: wm, workdayDays: work.count,
                    weekendMean: em, weekendDays: weekend.count, pValue: p, verdict: verdict)
    }
}
