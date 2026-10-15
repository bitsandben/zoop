import Foundation
import StrandAnalytics

/// The weekly routine schedule: which Lift Log programs are planned on which weekdays.
///
/// Stored as one JSON string in UserDefaults under `storageKey`, so views can bind it with
/// `@AppStorage` and every reader updates the moment a schedule is saved. It is a plan only —
/// nothing is written to the workout or lift tables until a session is actually run.
struct TrainingPlan: Codable, Equatable {
    /// Program id → `Calendar` weekday numbers (1 = Sunday … 7 = Saturday).
    var weekdays: [String: [Int]] = [:]
    /// One-off plans: local day key (yyyy-MM-dd) → program ids, e.g. a routine the coach proposed for
    /// today. Optional so plans saved before it existed still decode.
    var dates: [String: [String]]?
    /// The coach-built weekly plan: every session, strength ones with their program. Optional so
    /// plans saved before it existed still decode.
    var sessions: [PlanSession]?
    /// Name, kind and dates of the coach-built plan.
    var meta: Meta?

    struct Meta: Codable, Equatable {
        var name: String
        var focus: String?
        /// "open" or "targetDate".
        var kind: String
        /// Local yyyy-MM-dd.
        var startDay: String
        var targetDay: String?
    }

    static let storageKey = "zoop.trainingPlan.v1"

    static func decode(_ raw: String) -> TrainingPlan {
        guard let data = raw.data(using: .utf8),
              let plan = try? JSONDecoder().decode(TrainingPlan.self, from: data) else { return TrainingPlan() }
        return plan
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func days(for programId: String) -> Set<Int> { Set(weekdays[programId] ?? []) }

    mutating func set(_ days: Set<Int>, for programId: String) {
        let valid = days.filter { (1...7).contains($0) }.sorted()
        weekdays[programId] = valid.isEmpty ? nil : valid
    }

    /// Program ids planned on `date` (weekly plan plus one-off days), in a stable order.
    func programIds(on date: Date, calendar: Calendar = .current) -> [String] {
        let weekday = calendar.component(.weekday, from: date)
        let weekly = weekdays.filter { $0.value.contains(weekday) }.keys
        let oneOff = dates?[Self.dayKey(date, calendar: calendar)] ?? []
        return Set(weekly).union(oneOff).sorted()
    }

    /// Plans `programId` once on `date`, leaving the weekly plan alone. Past one-off days are dropped
    /// here so the list never grows.
    mutating func addOnce(_ programId: String, on date: Date, calendar: Calendar = .current) {
        let key = Self.dayKey(date, calendar: calendar)
        var map = (dates ?? [:]).filter { $0.key >= key }
        map[key] = Array(Set(map[key, default: []]).union([programId])).sorted()
        dates = map
    }

    /// Coach-plan sessions without a program on `date`, inside the plan's start / target dates.
    /// Strength sessions show through their program (`programIds(on:)`), so they are not repeated here.
    func plannedSessions(on date: Date, calendar: Calendar = .current) -> [PlanSession] {
        guard let sessions, !sessions.isEmpty else { return [] }
        let key = Self.dayKey(date, calendar: calendar)
        if let start = meta?.startDay, key < start { return [] }
        if let end = meta?.targetDay, key > end { return [] }
        let weekday = calendar.component(.weekday, from: date)
        return sessions.filter { $0.weekday == weekday && $0.programId == nil }
            .sorted { ($0.time ?? "") < ($1.time ?? "") }
    }

    /// The program weekdays follow the coach plan's strength sessions, so the calendar and the Lift
    /// Log agree after a plan is accepted, revised or undone.
    mutating func syncProgramWeekdays() {
        for (programId, rows) in Dictionary(grouping: (sessions ?? []).filter { $0.programId != nil },
                                            by: { $0.programId ?? "" }) {
            set(Set(rows.map(\.weekday)), for: programId)
        }
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
