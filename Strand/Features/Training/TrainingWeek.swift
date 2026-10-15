import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - The training week
//
// The seven days ending today, each with its sessions, its Effort and any Lift Log routine planned for
// it. "This week" means exactly this window everywhere on the page: the week card, the 7-day fatigue
// gauge and the muscle recovery card all look at the last seven days, and all count back from the clock
// rather than from the newest session. That anchor is the point: the old page counted "the last 7 days"
// from the latest session while the muscle card counted from now, so the two could state opposite
// things about the same week.

struct TrainingWeek {

    struct Day: Identifiable {
        /// Start of the local day.
        let date: Date
        /// Longest session first, so the lead session is the main one.
        let sessions: [WorkoutRow]
        /// The day's total Effort on the stored 0–100 axis; nil when the day has no figure.
        let effort: Double?
        let planned: [LiftProgramRow]
        let isToday: Bool
        /// Only the month calendar builds days after today; the week window ends on it.
        var isFuture = false
        /// Coach-plan sessions without a program planned on this day (only the month calendar fills it).
        var plannedSessions: [PlanSession] = []
        var id: Date { date }
    }

    let days: [Day]

    var sessions: [WorkoutRow] { days.flatMap(\.sessions) }
    var isEmpty: Bool { days.allSatisfy { $0.sessions.isEmpty } }

    /// Active time across the week's sessions, in seconds.
    var totalSeconds: Double { sessions.compactMap(\.durationS).reduce(0, +) }
    var totalKcal: Double { sessions.compactMap(\.energyKcal).reduce(0, +) }
    /// Duration-weighted heart-rate zone minutes; nil when no session carries a split.
    var zones: WorkoutZones.Summary? { WorkoutZones.summary(from: sessions) }

    /// Days in the window, today last.
    static let length = 7

    /// - Parameters:
    ///   - effortByDay: stored Effort per local `yyyy-MM-dd` key.
    ///   - planned: routines planned on a date (the Lift Log plan), looked up per day.
    static func make(rows: [WorkoutRow], effortByDay: [String: Double],
                     planned: (Date) -> [LiftProgramRow], now: Date = Date(),
                     calendar: Calendar = .current) -> TrainingWeek {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(length - 1), to: today) ?? today

        var byDay: [Date: [WorkoutRow]] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(row.startTs)))
            byDay[day, default: []].append(row)
        }

        let days = (0..<length).compactMap { offset -> Day? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let sessions = (byDay[date] ?? []).sorted { ($0.endTs - $0.startTs) > ($1.endTs - $1.startTs) }
            return Day(date: date, sessions: sessions, effort: effortByDay[dayKey(date, calendar: calendar)],
                       planned: planned(date), isToday: date == today)
        }
        return TrainingWeek(days: days)
    }

    /// Local `yyyy-MM-dd`, the key `DailyMetric.day` uses.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
