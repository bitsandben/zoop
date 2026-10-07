import Foundation
import WhoopProtocol

// PatternInsights.swift — small, pure readings of the user's own history for the iOS Patterns screen.
//
// Each function answers one question from data the app already stores and returns nil when there is not
// enough of it to say anything honest. They describe the user's past; none of them feeds a score.
//
// - bedtimeWindow: which half-hour of falling asleep is followed by the best recovery.
// - weekdayPattern: how a value differs by day of the week.
// - sleepNeedTonight: tonight's sleep need from the base need, today's strain and the sleep debt.
// - splitEffect: the mean outcome on the highest third of days for some driver against the lowest third.
// - windDown: how long after falling asleep the heart rate settles, and by how much it drops.

public enum PatternInsights {

    // MARK: Bedtime

    public struct BedtimeWindow: Equatable, Sendable {
        /// Start of the best half-hour, in minutes after midnight (may exceed 1440 for after-midnight).
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

    /// `nights` pairs the minute of sleep onset (minutes after local midnight; onsets after midnight are
    /// passed as 1440 + minutes so the evening and the small hours sort together) with the recovery that
    /// followed. Nil with fewer than 14 nights or no half-hour holding at least 3.
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
        /// Mean per weekday, 1 = Monday … 7 = Sunday, only for weekdays with enough days.
        public let means: [Int: Double]
        public let overall: Double
        public let best: Int
        public let worst: Int
    }

    static let minDaysPerWeekday = 3

    /// `values` pairs an ISO weekday (1 = Monday … 7 = Sunday) with a value. Nil unless at least five
    /// weekdays have three or more days each.
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

    // MARK: Sleep need

    public struct SleepNeed: Equatable, Sendable {
        public let totalMin: Double
        public let baseMin: Double
        public let strainMin: Double
        public let debtMin: Double
    }

    /// Strain above this (0–21 scale) adds sleep need.
    static let strainFreeUpTo = 10.0
    /// Extra minutes per strain point above `strainFreeUpTo`.
    static let minutesPerStrainPoint = 4.0
    /// Share of the outstanding debt asked back in one night, and the most asked back.
    static let debtRepayShare = 0.25
    static let debtRepayCapMin = 60.0

    /// `baseNeedMin` is the personal nightly need, `strain` today's strain on the 0–21 scale (nil when
    /// unknown), `debtMin` the outstanding sleep debt in minutes (0 or more).
    public static func sleepNeedTonight(baseNeedMin: Double, strain: Double?, debtMin: Double) -> SleepNeed {
        let strainMin = max(0, ((strain ?? 0) - strainFreeUpTo) * minutesPerStrainPoint)
        let debtPart = min(debtRepayCapMin, max(0, debtMin) * debtRepayShare)
        return SleepNeed(totalMin: baseNeedMin + strainMin + debtPart, baseMin: baseNeedMin,
                         strainMin: strainMin, debtMin: debtPart)
    }

    // MARK: Split effect

    public struct SplitEffect: Equatable, Sendable {
        public let lowMean: Double
        public let highMean: Double
        public let n: Int
        public var delta: Double { highMean - lowMean }
    }

    static let minDaysForSplit = 12

    /// Mean of `outcome` on the days in the top third of `driver` against the bottom third.
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
        /// Minutes after sleep onset until the heart rate first came within `settleMarginBpm` of its low.
        public let minutesToSettle: Int
        /// Mean heart rate in the quarter hour before onset minus the settled low.
        public let dropBpm: Double
    }

    static let preOnsetWindow = 15 * 60
    static let settleSearchWindow = 3 * 3600
    static let rollingWindow = 5 * 60
    static let settleMarginBpm = 2.0

    /// How long the heart rate takes to settle after `onset`, from samples covering the quarter hour
    /// before it and the three hours after. Nil when either side is too thin.
    public static func windDown(hr: [HRSample], onset: Int) -> WindDown? {
        let before = hr.filter { $0.ts >= onset - preOnsetWindow && $0.ts < onset }.map { Double($0.bpm) }
        guard before.count >= 10 else { return nil }
        // Per-minute means after onset, then a 5-minute rolling mean.
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
