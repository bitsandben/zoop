import Foundation

// MindfulOutcomes.swift - the two slower questions about a mindfulness practice.
//
// 1. Stress around a session: the hourly stress proxy (`DaytimeStress`, 0-3) in the hours before a
//    session against the hours after it. Hour buckets are coarse, so only whole scored hours that lie
//    entirely inside the 2 h before the start, or entirely inside the 2 h after the end, are used.
// 2. Days with vs without practice: the following night's resting HR / HRV on practice days against
//    other days of the same window. An observational comparison, not an effect estimate: a difference is
//    only called "clear" when both groups have `minDaysPerGroup` days and the gap exceeds twice its
//    standard error (Welch). Everything else reads as "no clear difference" or "not enough days".

public enum MindfulOutcomes {

    // MARK: - Stress before vs after a session

    /// How far around a session the stress hours are taken from.
    public static let stressWindowSeconds = 2 * 3_600

    public struct StressShift: Equatable, Sendable {
        public let before: Double
        public let after: Double
        /// Negative when stress fell after the session.
        public var change: Double { after - before }
    }

    /// Mean stress level of the scored hours before and after one session, or nil when either side has
    /// no fully contained scored hour.
    public static func stressShift(hours: [DaytimeStress.HourPoint], startTs: Int, endTs: Int) -> StressShift? {
        let w = stressWindowSeconds, b = DaytimeStress.bucketSeconds
        let before = hours.filter { $0.startTs >= startTs - w && $0.startTs + b <= startTs }.compactMap(\.level)
        let after = hours.filter { $0.startTs >= endTs && $0.startTs + b <= endTs + w }.compactMap(\.level)
        guard let mb = mean(before), let ma = mean(after) else { return nil }
        return StressShift(before: mb, after: ma)
    }

    public struct StressSummary: Equatable, Sendable {
        public let sessions: Int
        /// Mean change on the 0-3 scale (negative = calmer afterwards); nil below `minStressSessions`.
        public let meanChange: Double?
        /// Share of sessions followed by lower stress (0-1); nil below `minStressSessions`.
        public let calmerShare: Double?
    }

    public static let minStressSessions = 3

    public static func stressSummary(_ shifts: [StressShift]) -> StressSummary {
        let n = shifts.count
        guard n >= minStressSessions else { return StressSummary(sessions: n, meanChange: nil, calmerShare: nil) }
        return StressSummary(sessions: n, meanChange: mean(shifts.map(\.change)),
                             calmerShare: Double(shifts.filter { $0.change < 0 }.count) / Double(n))
    }

    // MARK: - Days with vs without practice

    public enum Comparison: Equatable, Sendable {
        case notEnoughDays
        case noClearDifference
        /// The practice-day mean is clearly above the other days' mean.
        case clearlyHigher
        case clearlyLower
    }

    public static let minDaysPerGroup = 5

    public struct DayContrast: Equatable, Sendable {
        public let withPractice: Double?
        public let withoutPractice: Double?
        public let daysWith: Int
        public let daysWithout: Int
        public let comparison: Comparison

        /// Practice-day mean minus other-day mean.
        public var difference: Double? {
            guard let a = withPractice, let b = withoutPractice else { return nil }
            return a - b
        }
    }

    /// Compares the night after each day: `values` is keyed by the morning ("YYYY-MM-DD") a nightly
    /// metric is filed under, `practiceDays` by the day practised, `days` lists the evaluated days.
    /// Day D is paired with the value filed on D + 1.
    public static func nextNightContrast(days: [String], practiceDays: Set<String>,
                                         values: [String: Double]) -> DayContrast {
        var with: [Double] = [], without: [Double] = []
        for d in days {
            guard let next = nextDay(d), let v = values[next] else { continue }
            if practiceDays.contains(d) { with.append(v) } else { without.append(v) }
        }
        return contrast(with, without)
    }

    static func contrast(_ a: [Double], _ b: [Double]) -> DayContrast {
        let ma = mean(a), mb = mean(b)
        var cmp = Comparison.notEnoughDays
        if a.count >= minDaysPerGroup, b.count >= minDaysPerGroup, let ma, let mb {
            let se = (variance(a) / Double(a.count) + variance(b) / Double(b.count)).squareRoot()
            let diff = ma - mb
            if se > 0, abs(diff) > 2 * se {
                cmp = diff > 0 ? .clearlyHigher : .clearlyLower
            } else {
                cmp = .noClearDifference
            }
        }
        return DayContrast(withPractice: ma, withoutPractice: mb, daysWith: a.count, daysWithout: b.count,
                           comparison: cmp)
    }

    // MARK: - Helpers

    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Sample variance (n - 1); 0 below two values.
    static func variance(_ xs: [Double]) -> Double {
        guard xs.count > 1, let m = mean(xs) else { return 0 }
        return xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The calendar day after a "YYYY-MM-DD" key.
    public static func nextDay(_ day: String) -> String? {
        guard let d = dayFormatter.date(from: day) else { return nil }
        return dayFormatter.string(from: d.addingTimeInterval(86_400))
    }
}
