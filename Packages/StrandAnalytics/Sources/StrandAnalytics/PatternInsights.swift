import Foundation
import WhoopProtocol

// Small pure readings of the user's own history for the iOS Patterns screen. Each returns nil when there is
// too little data to be honest, describes the past, and feeds no score: bedtimeWindow (half-hour of falling
// asleep followed by best recovery), weekdayPattern, splitEffect (top vs bottom third of a driver) and
// windDown (how long HR takes to settle after sleep onset).

public enum PatternInsights {

    // MARK: Bedtime

    public struct BedtimeWindow: Equatable, Sendable {
        /// Start of the best half-hour, minutes after midnight (may exceed 1440 for after-midnight).
        public let startMinute: Int
        public let endMinute: Int
        /// Mean next-day recovery for nights that began in the window, and for all nights.
        public let windowMean: Double
        public let overallMean: Double
        public let nights: Int
        public let nightsInWindow: Int
    }

    static let bedtimeBinMinutes = 30
    static let minNightsForBedtime = 14
    static let minNightsPerBin = 3

    /// `nights` pairs sleep-onset minute (after-midnight onsets passed as 1440 + minutes, so evening and small
    /// hours sort together) with the following recovery. Nil with fewer than 14 nights or no half-hour holding >= 3.
    public static func bedtimeWindow(nights: [(onsetMinute: Int, recovery: Double)]) -> BedtimeWindow? {
        guard nights.count >= minNightsForBedtime else { return nil }
        var bins: [Int: [Double]] = [:]
        for n in nights { bins[n.onsetMinute / bedtimeBinMinutes, default: []].append(n.recovery) }
        let overall = nights.map(\.recovery).reduce(0, +) / Double(nights.count)
        guard let best = bins.filter({ $0.value.count >= minNightsPerBin })
            .max(by: { mean($0.value) < mean($1.value) }) else { return nil }
        return BedtimeWindow(startMinute: best.key * bedtimeBinMinutes,
                             endMinute: (best.key + 1) * bedtimeBinMinutes,
                             windowMean: mean(best.value), overallMean: overall,
                             nights: nights.count, nightsInWindow: best.value.count)
    }

    // MARK: Weekday

    public struct WeekdayPattern: Equatable, Sendable {
        /// Mean per weekday (1 = Monday ... 7 = Sunday), only for weekdays with enough days.
        public let means: [Int: Double]
        public let overall: Double
        public let best: Int
        public let worst: Int
    }

    static let minDaysPerWeekday = 3

    /// `values` pairs an ISO weekday with a value. Nil unless at least five weekdays have three or more days each.
    public static func weekdayPattern(_ values: [(weekday: Int, value: Double)]) -> WeekdayPattern? {
        var groups: [Int: [Double]] = [:]
        for v in values where (1...7).contains(v.weekday) { groups[v.weekday, default: []].append(v.value) }
        let means = groups.filter { $0.value.count >= minDaysPerWeekday }.mapValues(mean)
        guard means.count >= 5,
              let best = means.max(by: { $0.value < $1.value })?.key,
              let worst = means.min(by: { $0.value < $1.value })?.key else { return nil }
        let all = values.map(\.value)
        return WeekdayPattern(means: means, overall: mean(all), best: best, worst: worst)
    }

    // MARK: Time in bed

    /// Minutes in bed to sleep `goal` (0.5-1.0) of `needMin` given sleep efficiency (fraction or percentage; nil or
    /// implausible falls back to 0.9, held to 0.75-0.98 so one odd night can't swing the plan).
    public static func inBedMinutes(needMin: Double, goal: Double, efficiency: Double?) -> Double {
        var e = efficiency ?? 0.9
        if e > 1 { e /= 100 }
        if !(0.5...1).contains(e) { e = 0.9 }
        e = min(0.98, max(0.75, e))
        return needMin * min(1, max(0.5, goal)) / e
    }

    // MARK: Split effect

    public struct SplitEffect: Equatable, Sendable {
        public let lowMean: Double
        public let highMean: Double
        public let n: Int
        public var delta: Double { highMean - lowMean }
    }

    static let minDaysForSplit = 12

    /// Mean outcome on the top third of `driver` days against the bottom third.
    public static func splitEffect(_ pairs: [(driver: Double, outcome: Double)]) -> SplitEffect? {
        guard pairs.count >= minDaysForSplit else { return nil }
        let sorted = pairs.sorted { $0.driver < $1.driver }
        let third = sorted.count / 3
        let low = sorted.prefix(third).map(\.outcome)
        let high = sorted.suffix(third).map(\.outcome)
        return SplitEffect(lowMean: mean(low), highMean: mean(high), n: pairs.count)
    }

    // MARK: Wind-down

    public struct WindDown: Equatable, Sendable {
        /// Minutes after sleep onset until HR first came within `settleMarginBpm` of its low.
        public let minutesToSettle: Int
        /// Mean HR in the quarter hour before onset minus the settled low.
        public let dropBpm: Double
    }

    static let preOnsetWindow = 15 * 60
    static let settleSearchWindow = 3 * 3600
    static let rollingWindow = 5 * 60
    static let settleMarginBpm = 2.0

    /// How long HR takes to settle after `onset`, from samples covering the quarter hour before and three hours after; nil when either side is too thin.
    public static func windDown(hr: [HRSample], onset: Int) -> WindDown? {
        let before = hr.filter { $0.ts >= onset - preOnsetWindow && $0.ts < onset }.map { Double($0.bpm) }
        guard before.count >= 10 else { return nil }
        // Per-minute means, then a 5-minute rolling mean.
        var minutes: [Int: (Double, Int)] = [:]
        for s in hr where s.ts >= onset && s.ts < onset + settleSearchWindow {
            let m = (s.ts - onset) / 60
            let cur = minutes[m] ?? (0, 0)
            minutes[m] = (cur.0 + Double(s.bpm), cur.1 + 1)
        }
        let span = rollingWindow / 60
        var rolling: [(minute: Int, bpm: Double)] = []
        for m in 0...(settleSearchWindow / 60 - span) {
            let vals = (m..<(m + span)).compactMap { minutes[$0] }.map { $0.0 / Double($0.1) }
            if vals.count >= span - 1 { rolling.append((m, vals.reduce(0, +) / Double(vals.count))) }
        }
        guard rolling.count >= 12, let low = rolling.map(\.bpm).min(),
              let settled = rolling.first(where: { $0.bpm <= low + settleMarginBpm }) else { return nil }
        return WindDown(minutesToSettle: settled.minute, dropBpm: mean(before) - low)
    }

    static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
}
