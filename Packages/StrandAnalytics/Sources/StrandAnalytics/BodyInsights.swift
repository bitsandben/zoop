import Foundation
import WhoopStore

// Interpretations of the user's own history, one plain statement each. Every reading returns nil
// when there is too little data; the engine is locale-free (typed numbers, a state, a chart series)
// and none of it feeds a score.
// - direction: is HRV (or resting HR) away from its own normal, and for how many days in a row?
// - weekday: is one weekday reliably the low (or high) point of the recovery week?
// - bounceBack: after the hardest days, how many mornings until recovery is back at normal?
// - zoneMix: share of recent training time easy (zones 1-2) vs hard (zones 3-5).
// - stressTiming: the hour stress usually peaks, and the calmest one.
// - strainSensitivity: how much a harder day lowers next morning's recovery, per 10 effort points.
// Neighbours, to avoid double computation: `ReadinessEngine` scores one day's z-score (this reads the
// run of days); `ActivityCostEngine` costs tagged sports against rest days (this measures every hard
// day against its own trailing month); `PatternInsights.weekdayPattern` draws every weekday's mean
// (this speaks only when one stands out). `strainSensitivity` reuses `PatternInsights.splitEffect`,
// and bounce-back uses `ActivityCostEngine.tolerance`.

public enum BodyInsights {

    // MARK: Shared input types

    /// One value on one local day ("yyyy-MM-dd").
    public struct DayValue: Equatable, Sendable {
        public let day: String
        public let value: Double
        public init(day: String, value: Double) { self.day = day; self.value = value }
    }

    /// One day's effort (Zoop 0-100 strain) and that morning's recovery (0-100). Recovery on `day` belongs to
    /// the night before, so the morning after a day's effort is the next row's recovery.
    public struct DayLoad: Equatable, Sendable {
        public let day: String
        public let strain: Double?
        public let recovery: Double?
        public init(day: String, strain: Double?, recovery: Double?) {
            self.day = day; self.strain = strain; self.recovery = recovery
        }
    }

    // MARK: - 1. Direction (HRV / resting HR against the personal normal)

    public enum Trend: String, Equatable, Sendable {
        /// The latest `streakDays` readings in a row sit clearly below the normal.
        case belowStreak
        /// The latest `streakDays` readings in a row sit clearly above the normal.
        case aboveStreak
        /// No run of days, but the last seven days average clearly below the normal.
        case lowerThisWeek
        /// No run of days, but the last seven days average clearly above the normal.
        case higherThisWeek
        /// Within the usual range.
        case steady
    }

    public struct Direction: Equatable, Sendable {
        public let trend: Trend
        /// Consecutive latest readings beyond `zThreshold` on the same side (0 when no run).
        public let streakDays: Int
        /// Mean of the last seven days, and of the thirty days before them.
        public let recentMean: Double
        public let baselineMean: Double
        public let baselineSD: Double
        /// (recent − baseline) / baseline × 100.
        public let deltaPercent: Double
        /// The last 30 days of readings, oldest first, for the chart.
        public let series: [DayValue]
    }

    /// A day is away from normal at half a standard deviation from its trailing month.
    static let zThreshold = 0.5
    /// A run of this many days is worth saying out loud.
    static let minStreak = 3
    static let baselineDays = 30
    static let recentDays = 7
    static let minBaselineValues = 14
    static let minRecentValues = 4
    /// The latest reading must be at most this many days before `asOf`.
    static let maxStaleDays = 3

    /// Where `values` stands against its own normal. `asOf` ("yyyy-MM-dd", usually today) makes a stale
    /// history say nothing. Nil without 14 readings in the 30 days before the last week and 4 in it.
    public static func direction(_ values: [DayValue], asOf: String? = nil) -> Direction? {
        let byDay = dayMap(values)
        guard let last = byDay.keys.max() else { return nil }
        if let asOf, let today = dayNumber(asOf), today - last > maxStaleDays { return nil }

        let recent = (last - recentDays + 1...last).compactMap { byDay[$0] }
        let base = (last - recentDays - baselineDays + 1...last - recentDays).compactMap { byDay[$0] }
        guard recent.count >= minRecentValues, base.count >= minBaselineValues else { return nil }
        let baseMean = mean(base)
        let baseSD = sdFloor(sd(base), mean: baseMean)
        let recentMean = mean(recent)

        // The run: walk back from the latest reading while each sits beyond the threshold on the same side,
        // against its own trailing month. One missing day is tolerated.
        func z(_ day: Int) -> Double? {
            guard let v = byDay[day] else { return nil }
            let prior = (day - baselineDays...day - 1).compactMap { byDay[$0] }
            guard prior.count >= minBaselineValues else { return nil }
            let m = mean(prior)
            return (v - m) / sdFloor(sd(prior), mean: m)
        }
        var streak = 0
        var side = 0
        if let z0 = z(last), abs(z0) >= zThreshold {
            side = z0 < 0 ? -1 : 1
            var day = last
            var gap = 0
            while day > last - baselineDays {
                if let zd = z(day) {
                    if Double(side) * zd >= zThreshold { streak += 1; gap = 0 } else { break }
                } else {
                    gap += 1
                    if gap > 1 { break }
                }
                day -= 1
            }
        }

        let trend: Trend
        let weekZ = (recentMean - baseMean) / baseSD
        if streak >= minStreak {
            trend = side < 0 ? .belowStreak : .aboveStreak
        } else if weekZ <= -zThreshold {
            trend = .lowerThisWeek
        } else if weekZ >= zThreshold {
            trend = .higherThisWeek
        } else {
            trend = .steady
        }
        let series = (last - baselineDays + 1...last).compactMap { d in
            byDay[d].map { DayValue(day: dayString(d), value: $0) }
        }
        return Direction(trend: trend, streakDays: streak >= minStreak ? streak : 0,
                         recentMean: recentMean, baselineMean: baseMean, baselineSD: baseSD,
                         deltaPercent: baseMean == 0 ? 0 : (recentMean - baseMean) / baseMean * 100,
                         series: series)
    }

    // MARK: - 2. Weekday

    public struct WeekdayEffect: Equatable, Sendable {
        /// ISO weekday, 1 = Monday … 7 = Sunday.
        public let weekday: Int
        public let mean: Double
        /// Mean of every other day.
        public let othersMean: Double
        /// Share of weeks in which this weekday sat on the same side of that week's other days.
        public let consistency: Double
        public let weeks: Int
        public var gap: Double { mean - othersMean }
    }

    public struct WeekdayReading: Equatable, Sendable {
        public let lowest: WeekdayEffect?
        public let highest: WeekdayEffect?
        /// Mean per ISO weekday (only weekdays with enough readings).
        public let means: [Int: Double]
        public let weeks: Int
    }

    static let weekdayWindowDays = 182
    static let minWeeks = 8
    static let minPerWeekday = 6
    static let minWeekdayGap = 8.0
    static let minConsistency = 0.65

    /// The weekday whose recovery is reliably lowest (and highest) over the last 26 weeks: its mean sits at
    /// least 8 points from the other days and it was on that side of its own week in at least 65% of weeks.
    /// Nil with fewer than 8 weeks or nothing standing out.
    public static func weekday(_ recovery: [DayValue]) -> WeekdayReading? {
        let byDay = dayMap(recovery)
        guard let last = byDay.keys.max() else { return nil }
        let window = byDay.filter { $0.key > last - weekdayWindowDays }
        var groups: [Int: [Double]] = [:]
        var weeks: [Int: [Int: Double]] = [:]
        for (d, v) in window {
            groups[isoWeekday(d), default: []].append(v)
            weeks[weekIndex(d), default: [:]][isoWeekday(d)] = v
        }
        guard weeks.count >= minWeeks else { return nil }
        let means = groups.filter { $0.value.count >= minPerWeekday }.mapValues(mean)
        guard means.count >= 6 else { return nil }

        func effect(_ wd: Int, low: Bool) -> WeekdayEffect? {
            guard let m = means[wd] else { return nil }
            let others = window.filter { isoWeekday($0.key) != wd }.map(\.value)
            guard !others.isEmpty else { return nil }
            let om = mean(others)
            guard (low ? om - m : m - om) >= minWeekdayGap else { return nil }
            var hits = 0, total = 0
            for (_, week) in weeks {
                guard let v = week[wd] else { continue }
                let rest = week.filter { $0.key != wd }.map(\.value)
                guard rest.count >= 3 else { continue }
                total += 1
                if low ? v < mean(rest) : v > mean(rest) { hits += 1 }
            }
            guard total >= minWeeks else { return nil }
            let share = Double(hits) / Double(total)
            guard share >= minConsistency else { return nil }
            return WeekdayEffect(weekday: wd, mean: m, othersMean: om, consistency: share, weeks: total)
        }
        let lowWd = means.min { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key
        let highWd = means.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
        let lowest = lowWd.flatMap { effect($0, low: true) }
        let highest = highWd.flatMap { effect($0, low: false) }
        guard lowest != nil || highest != nil else { return nil }
        return WeekdayReading(lowest: lowest, highest: highest, means: means, weeks: weeks.count)
    }

    // MARK: - 3. Bounce-back after hard days

    public struct BounceBack: Equatable, Sendable {
        /// Median mornings until recovery is back within `ActivityCostEngine.tolerance` of normal. Hard days
        /// not recovered after a week count as 8, so above 7 means "over a week".
        public let medianDays: Double
        /// Hard days measured, and how many of them were still below normal a week later.
        public let events: Int
        public let unresolved: Int
        /// Mean gap between the next morning's recovery and the normal (negative = below).
        public let nextMorningDip: Double
        /// The effort (0–100) at and above which a day counts as hard: the user's top 20 %.
        public let hardThreshold: Double
        /// Mean gap to the normal on the morning of the hard day (k = 0) and the seven after it.
        public let trajectory: [Double?]
    }

    static let bounceWindowDays = 365
    static let minStrainDays = 30
    static let hardQuantile = 0.8
    static let bounceLookahead = 7
    static let minBaselineForBounce = 10
    static let minBounceEvents = 5

    /// After days in the user's top 20% of effort, how many mornings until recovery is back at normal; each
    /// hard day is measured against the median recovery of the 30 days before it. Nil with fewer than 30
    /// effort days or 5 measurable hard days.
    public static func bounceBack(_ days: [DayLoad]) -> BounceBack? {
        let (strain, recovery) = loadMaps(days)
        guard let last = (Array(strain.keys) + Array(recovery.keys)).max() else { return nil }
        let window = strain.filter { $0.key > last - bounceWindowDays }
        guard window.count >= minStrainDays else { return nil }
        let threshold = quantile(Array(window.values), hardQuantile)
        guard threshold > 0 else { return nil }
        let tol = ActivityCostEngine.tolerance

        var outcomes: [Int] = []
        var dips: [Double] = []
        var traj = [[Double]](repeating: [], count: bounceLookahead + 1)
        for (d, s) in window.sorted(by: { $0.key < $1.key }) where s >= threshold {
            let prior = (d - baselineDays...d - 1).compactMap { recovery[$0] }
            guard prior.count >= minBaselineForBounce else { continue }
            let normal = median(prior)
            for k in 0...bounceLookahead { if let r = recovery[d + k] { traj[k].append(r - normal) } }
            if let r1 = recovery[d + 1] { dips.append(r1 - normal) }
            var resolved: Int?
            var seen = 0
            for k in 1...bounceLookahead {
                guard let r = recovery[d + k] else { continue }
                seen += 1
                if r >= normal - tol { resolved = k; break }
            }
            if let k = resolved {
                outcomes.append(k)
            } else if seen > 0 && d + bounceLookahead <= last {
                outcomes.append(bounceLookahead + 1)
            }
        }
        guard outcomes.count >= minBounceEvents else { return nil }
        let unresolved = outcomes.filter { $0 > bounceLookahead }.count
        return BounceBack(medianDays: median(outcomes.map(Double.init)), events: outcomes.count,
                          unresolved: unresolved, nextMorningDip: dips.isEmpty ? 0 : mean(dips),
                          hardThreshold: threshold,
                          trajectory: traj.map { $0.isEmpty ? nil : mean($0) })
    }

    // MARK: - 4. Heart-rate zone mix

    public enum ZoneMixStyle: String, Equatable, Sendable {
        /// At least 75% of training time in zones 1-2 (close to an 80/20 split).
        case mostlyEasy
        /// Between half and three quarters easy.
        case mixed
        /// Less than half easy.
        case mostlyHard
    }

    public struct ZoneMix: Equatable, Sendable {
        /// Minutes in zones 1…5 summed over the sessions.
        public let minutes: [Double]
        public let sessions: Int
        public var totalMinutes: Double { minutes.reduce(0, +) }
        /// Share (0–1) of zone time in zones 1–2, and in zones 3–5.
        public var easyShare: Double { totalMinutes > 0 ? (minutes[0] + minutes[1]) / totalMinutes : 0 }
        public var hardShare: Double { totalMinutes > 0 ? 1 - easyShare : 0 }
        public var style: ZoneMixStyle {
            easyShare >= 0.75 ? .mostlyEasy : easyShare >= 0.5 ? .mixed : .mostlyHard
        }
    }

    static let minZoneSessions = 3
    static let minZoneMinutes = 90.0

    /// Sums per-session zone minutes (arrays are zones 1...5; shorter padded, extras ignored). The caller
    /// picks the window (the app uses four weeks). Nil with fewer than 3 sessions with zone time or under
    /// 90 minutes total.
    public static func zoneMix(sessions: [[Double]]) -> ZoneMix? {
        var total = [Double](repeating: 0, count: 5)
        var n = 0
        for s in sessions {
            let m = (0..<5).map { $0 < s.count ? max(0, s[$0]) : 0 }
            guard m.reduce(0, +) > 0 else { continue }
            for i in 0..<5 { total[i] += m[i] }
            n += 1
        }
        guard n >= minZoneSessions, total.reduce(0, +) >= minZoneMinutes else { return nil }
        return ZoneMix(minutes: total, sessions: n)
    }

    // MARK: - 5. Stress timing

    public struct HourLevel: Equatable, Sendable {
        /// Local hour, 0–23.
        public let hour: Int
        /// The shared 0–3 stress level.
        public let level: Double
        public init(hour: Int, level: Double) { self.hour = hour; self.level = level }
    }

    public struct StressTiming: Equatable, Sendable {
        public let peakHour: Int
        public let calmHour: Int
        public let peakMean: Double
        public let calmMean: Double
        /// Share of days on which the peak hour sat above that day's own mean.
        public let consistency: Double
        public let days: Int
        /// Mean level per hour, ascending by hour, for the chart.
        public let hourMeans: [HourLevel]
    }

    static let minStressDays = 7
    static let minScoredHoursPerDay = 6
    static let minDaysPerHour = 4
    static let minStressSpread = 0.4
    static let minPeakConsistency = 0.6

    /// The hour stress usually peaks and the calmest hour, from hourly levels (one array per day). Nil with
    /// fewer than 7 days of 6+ scored hours, a spread under 0.4 on the 0-3 scale, or a peak leading on
    /// fewer than 60% of days.
    public static func stressTiming(days: [[HourLevel]]) -> StressTiming? {
        let (usable, means) = StressPatterns.hourMeans(days)
        guard usable.count >= minStressDays, means.count >= minScoredHoursPerDay,
              let peak = means.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }),
              let calm = means.min(by: { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }),
              peak.value - calm.value >= minStressSpread else { return nil }
        var hits = 0, total = 0
        for d in usable {
            guard let v = d.first(where: { $0.hour == peak.key })?.level else { continue }
            total += 1
            if v > mean(d.map(\.level)) { hits += 1 }
        }
        let share = total == 0 ? 0 : Double(hits) / Double(total)
        guard share >= minPeakConsistency else { return nil }
        return StressTiming(peakHour: peak.key, calmHour: calm.key, peakMean: peak.value,
                            calmMean: calm.value, consistency: share, days: usable.count,
                            hourMeans: means.keys.sorted().map { HourLevel(hour: $0, level: means[$0]!) })
    }

    // MARK: - 6. Strain sensitivity

    public enum Sensitivity: String, Equatable, Sendable {
        /// 3 or more recovery points lower per 10 effort points.
        case strong
        /// 1 to 3 points lower per 10 effort points.
        case noticeable
        /// Less than 1 point (or recovery rises with effort).
        case little
    }

    public struct StrainSensitivity: Equatable, Sendable {
        /// Least-squares change in next-morning recovery per 10 effort points (0–100 scale).
        public let pointsPer10: Double
        /// Pearson r between the day's effort and the next morning's recovery.
        public let correlation: Double
        /// Next-morning recovery after the hardest third of days minus after the easiest third.
        public let splitDelta: Double
        public let pairs: Int
        public var level: Sensitivity {
            pointsPer10 <= -3 ? .strong : pointsPer10 <= -1 ? .noticeable : .little
        }
        /// (effort, next-morning recovery), oldest first, for the scatter.
        public let points: [Pair]
        public struct Pair: Equatable, Sendable {
            public let strain: Double
            public let recovery: Double
            public init(strain: Double, recovery: Double) { self.strain = strain; self.recovery = recovery }
        }
    }

    static let sensitivityWindowDays = 180
    static let minSensitivityPairs = 21
    static let minStrainSD = 3.0

    /// How much a harder day lowers next morning's recovery, from the last 180 days of (effort on D,
    /// recovery on D+1). Nil with fewer than 21 pairs or effort that barely varies.
    public static func strainSensitivity(_ days: [DayLoad]) -> StrainSensitivity? {
        let (strain, recovery) = loadMaps(days)
        guard let last = recovery.keys.max() else { return nil }
        var pairs: [StrainSensitivity.Pair] = []
        for d in strain.keys.sorted() where d >= last - sensitivityWindowDays {
            guard let s = strain[d], let r = recovery[d + 1] else { continue }
            pairs.append(.init(strain: s, recovery: r))
        }
        guard pairs.count >= minSensitivityPairs else { return nil }
        let xs = pairs.map(\.strain), ys = pairs.map(\.recovery)
        let sx = sd(xs), sy = sd(ys)
        guard sx >= minStrainSD else { return nil }
        let mx = mean(xs), my = mean(ys)
        var cov = 0.0
        for i in xs.indices { cov += (xs[i] - mx) * (ys[i] - my) }
        cov /= Double(xs.count - 1)
        let slope = cov / (sx * sx)
        let r = sy > 0 ? cov / (sx * sy) : 0
        guard let split = PatternInsights.splitEffect(pairs.map { (driver: $0.strain, outcome: $0.recovery) })
        else { return nil }
        return StrainSensitivity(pointsPer10: slope * 10, correlation: r, splitDelta: split.delta,
                                 pairs: pairs.count, points: pairs)
    }

    // MARK: - Convenience over the stored daily rows

    public static func hrv(_ days: [DailyMetric]) -> [DayValue] {
        days.compactMap { d in d.avgHrv.flatMap { $0 > 0 ? DayValue(day: d.day, value: $0) : nil } }
    }

    public static func restingHR(_ days: [DailyMetric]) -> [DayValue] {
        days.compactMap { d in d.restingHr.flatMap { $0 > 0 ? DayValue(day: d.day, value: Double($0)) : nil } }
    }

    public static func recovery(_ days: [DailyMetric]) -> [DayValue] {
        days.compactMap { d in d.recovery.map { DayValue(day: d.day, value: $0) } }
    }

    public static func loads(_ days: [DailyMetric]) -> [DayLoad] {
        days.map { DayLoad(day: $0.day, strain: $0.strain, recovery: $0.recovery) }
    }

    // MARK: - Day arithmetic (days since 1970-01-01, no Calendar)

    /// "yyyy-MM-dd" to days since 1970-01-01, or nil.
    static func dayNumber(_ s: String) -> Int? {
        let p = s.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        // Hinnant days_from_civil.
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func dayString(_ n: Int) -> String {
        let z = n + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// ISO weekday, 1 = Monday … 7 = Sunday (1970-01-01 was a Thursday).
    static func isoWeekday(_ n: Int) -> Int { ((n + 3) % 7 + 7) % 7 + 1 }

    /// Monday-based week number.
    static func weekIndex(_ n: Int) -> Int { Int((Double(n + 3) / 7).rounded(.down)) }

    static func dayMap(_ values: [DayValue]) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for v in values where v.value.isFinite { if let n = dayNumber(v.day) { out[n] = v.value } }
        return out
    }

    static func loadMaps(_ days: [DayLoad]) -> (strain: [Int: Double], recovery: [Int: Double]) {
        var s: [Int: Double] = [:], r: [Int: Double] = [:]
        for d in days {
            guard let n = dayNumber(d.day) else { continue }
            if let v = d.strain, v.isFinite { s[n] = v }
            if let v = d.recovery, v.isFinite { r[n] = v }
        }
        return (s, r)
    }

    // MARK: - Small statistics

    static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

    /// Sample standard deviation (n − 1); 0 for fewer than two values.
    static func sd(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let m = mean(v)
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1)).squareRoot()
    }

    /// Hold the spread at 3% of the mean so a very steady baseline does not turn a one-unit wobble into a large z.
    static func sdFloor(_ s: Double, mean m: Double) -> Double { max(s, abs(m) * 0.03, 1e-9) }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Nearest-rank quantile.
    static func quantile(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let idx = min(s.count - 1, max(0, Int((q * Double(s.count)).rounded(.up)) - 1))
        return s[idx]
    }
}
