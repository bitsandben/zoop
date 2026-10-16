import Foundation
import StrandAnalytics
import StrandDesign
import StrandImport
import WhoopStore

/// This calendar week of the coach plan, each planned session with whether it was done, missed, is
/// today or still ahead. A session counts as done when a workout of the same sport (or, for strength,
/// any strength workout) was logged on its day.
enum PlanWeekStatus {

    enum State: Equatable { case done, missed, today, upcoming }

    struct Entry: Identifiable, Equatable {
        let session: PlanSession
        let date: Date
        let state: State
        var id: String { session.id }
    }

    static func week(plan: TrainingPlan, workouts: [WorkoutRow], now: Date = Date(),
                     calendar: Calendar = .current) -> [Entry] {
        guard let sessions = plan.sessions, !sessions.isEmpty,
              let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: [String]] = [:]
        for w in workouts {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(w.startTs)))
            byDay[day, default: []].append(w.sport)
        }
        var entries: [Entry] = []
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: interval.start) else { continue }
            let key = TrainingPlan.dayKey(date, calendar: calendar)
            if let start = plan.meta?.startDay, key < start { continue }
            if let end = plan.meta?.targetDay, key > end { continue }
            let weekday = calendar.component(.weekday, from: date)
            for session in sessions.filter({ $0.weekday == weekday }).sorted(by: { ($0.time ?? "") < ($1.time ?? "") }) {
                let done = (byDay[date] ?? []).contains { matches($0, session.sport) }
                let state: State = done ? .done : date < today ? .missed : date == today ? .today : .upcoming
                entries.append(Entry(session: session, date: date, state: state))
            }
        }
        return entries
    }

    static func matches(_ workoutSport: String, _ plannedSport: String) -> Bool {
        let a = KnownWorkoutType.resolving(workoutSport), b = KnownWorkoutType.resolving(plannedSport)
        if let a, let b { return a == b || (isStrength(a) && isStrength(b)) }
        return workoutSport.caseInsensitiveCompare(plannedSport) == .orderedSame
    }

    private static func isStrength(_ type: KnownWorkoutType) -> Bool {
        switch type {
        case .strength, .bodybuilding, .weightlifting, .crossfit, .calisthenics: return true
        default: return false
        }
    }
}
