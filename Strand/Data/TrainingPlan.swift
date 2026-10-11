import Foundation

/// The weekly routine schedule: which Lift Log programs are planned on which weekdays.
///
/// Stored as one JSON string in UserDefaults under `storageKey`, so views can bind it with
/// `@AppStorage` and every reader updates the moment a schedule is saved. It is a plan only —
/// nothing is written to the workout or lift tables until a session is actually run.
struct TrainingPlan: Codable, Equatable {
    /// Program id → `Calendar` weekday numbers (1 = Sunday … 7 = Saturday).
    var weekdays: [String: [Int]] = [:]

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

    /// Program ids planned on the weekday of `date`, in a stable order.
    func programIds(on date: Date, calendar: Calendar = .current) -> [String] {
        let weekday = calendar.component(.weekday, from: date)
        return weekdays.filter { $0.value.contains(weekday) }.keys.sorted()
    }
}
