import Foundation

// MARK: - Fasting history: week, streak, consistency, and the night split for patterns
//
// A fast belongs to the calendar day it ended on, so an overnight 20:00-12:00 fast doesn't count for two days.

/// One day of the weekly chart.
public struct FastingDay: Equatable, Sendable {
    public let dayStart: Date
    /// Longest fast ending that day (a running fast counts for today with its elapsed time).
    public let fasted: TimeInterval
    public let goal: TimeInterval?
    public let met: Bool
    public let inProgress: Bool
}

/// Goal-met days over a window. `consideredDays` never reaches back before the first logged fast.
public struct FastingConsistency: Equatable, Sendable {
    public let metDays: Int
    public let consideredDays: Int
}

/// Wake-days whose night was inside a logged fast vs. nights with no logged fast at all.
public struct FastingNightSplit: Equatable, Sendable {
    public let fasting: Set<String>
    public let control: Set<String>
}

/// Result of comparing an overnight outcome on fasting vs. other nights.
public enum FastingComparison: Equatable, Sendable {
    case notEnoughData(fastingNights: Int, otherNights: Int, needed: Int)
    case noClearDifference(BehaviorEffect)
    case difference(BehaviorEffect)
}

public extension FastingEngine {

    /// Minimum logged fast for a fasting night: the shortest preset; shorter logs are ordinary overnight gaps.
    static let minFastingNight: TimeInterval = 12 * 3600

    /// The window that decides the split: local [00:00, 05:00) of the wake-day, where overnight HR and HRV are measured.
    static let nightWindowHours: (start: Int, end: Int) = (0, 5)

    /// The last `days` calendar days ending today, oldest first.
    static func week(_ intervals: [FastingInterval], now: Date, days: Int = 7,
                     calendar: Calendar) -> [FastingDay] {
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(grouping: intervals) { calendar.startOfDay(for: $0.end ?? now) }
        return (0..<max(days, 1)).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let best = byDay[day]?.max { $0.duration(now: now) < $1.duration(now: now) }
            guard let best else {
                return FastingDay(dayStart: day, fasted: 0, goal: nil, met: false, inProgress: false)
            }
            return FastingDay(dayStart: day, fasted: best.duration(now: now), goal: best.goal,
                              met: best.duration(now: now) >= best.goal, inProgress: best.isActive)
        }
    }

    /// Consecutive goal-met days counting back from today. Today without one yet doesn't break the streak.
    static func streak(_ intervals: [FastingInterval], now: Date, calendar: Calendar) -> Int {
        let metDays = metDaySet(intervals, now: now, calendar: calendar)
        var day = calendar.startOfDay(for: now)
        if !metDays.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while metDays.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// Goal-met days in the last `days` days; today counts only once met.
    static func consistency(_ intervals: [FastingInterval], now: Date, days: Int,
                            calendar: Calendar) -> FastingConsistency {
        guard let first = intervals.map(\.start).min() else {
            return FastingConsistency(metDays: 0, consideredDays: 0)
        }
        let metDays = metDaySet(intervals, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.startOfDay(for: first)
        var met = 0, considered = 0
        for back in 0..<max(days, 1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today), day >= firstDay else { break }
            let isMet = metDays.contains(day)
            if day == today && !isMet { continue }
            considered += 1
            if isMet { met += 1 }
        }
        return FastingConsistency(metDays: met, consideredDays: considered)
    }

    /// Splits wake-days (yyyy-MM-dd) into nights inside a logged fast of at least 12 h and nights with no
    /// logged fast touching the window. Partly covered nights and everything before the first logged
    /// fast are dropped: an unlogged day is unknown, not a "no" (same rule as `BehaviorInsights.effect`).
    static func nightSplit(_ intervals: [FastingInterval], now: Date, calendar: Calendar) -> FastingNightSplit {
        guard let first = intervals.map(\.start).min() else { return FastingNightSplit(fasting: [], control: []) }
        var fasting = Set<String>(), control = Set<String>()
        var day = calendar.startOfDay(for: first)
        let today = calendar.startOfDay(for: now)
        while day <= today {
            guard let windowStart = calendar.date(byAdding: .hour, value: nightWindowHours.start, to: day),
                  let windowEnd = calendar.date(byAdding: .hour, value: nightWindowHours.end, to: day),
                  windowEnd <= now else { break }
            let touching = intervals.filter { $0.start < windowEnd && ($0.end ?? now) > windowStart }
            if touching.isEmpty {
                control.insert(dayKey(day, calendar: calendar))
            } else if touching.contains(where: {
                $0.start <= windowStart && ($0.end ?? now) >= windowEnd && $0.duration(now: now) >= minFastingNight
            }) {
                fasting.insert(dayKey(day, calendar: calendar))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return FastingNightSplit(fasting: fasting, control: control)
    }

    /// Compares one overnight outcome (keyed by wake-day) between the groups. Numbers appear only once
    /// both groups reach the patterns minimum, and "difference" only when the Welch test clears
    /// `BehaviorInsights.alpha`; otherwise "no clear difference".
    static func compare(split: FastingNightSplit, outcomeByDay: [String: Double],
                        outcome: String) -> FastingComparison {
        let needed = BehaviorInsights.minGroupForSignificance
        let nFast = split.fasting.filter { outcomeByDay[$0] != nil }.count
        let nOther = split.control.filter { outcomeByDay[$0] != nil }.count
        guard nFast >= needed, nOther >= needed,
              let effect = BehaviorInsights.effect(behaviorDays: split.fasting, controlDays: split.control,
                                                   outcomeByDay: outcomeByDay, behavior: "Fasting",
                                                   outcome: outcome) else {
            return .notEnoughData(fastingNights: nFast, otherNights: nOther, needed: needed)
        }
        return effect.significant ? .difference(effect) : .noClearDifference(effect)
    }

    /// yyyy-MM-dd in the calendar's zone, the key `DailyMetric.day` uses.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Days with a goal-met fast. A running fast already past its goal counts for today.
    private static func metDaySet(_ intervals: [FastingInterval], now: Date, calendar: Calendar) -> Set<Date> {
        Set(intervals.compactMap { i in
            let reached = i.metGoal || (i.isActive && i.duration(now: now) >= i.goal)
            return reached ? calendar.startOfDay(for: i.end ?? now) : nil
        })
    }
}
