import Foundation
import StrandAnalytics

/// What the native plan form collects, and how it reads as the interview answers the provider gets.
struct PlanFormState: Equatable {
    var goals: Set<String> = []
    var goalText = ""
    var openEnded = true
    var targetDate = Calendar.current.date(byAdding: .day, value: 84, to: Date()) ?? Date()
    var weekdays: Set<Int> = [2, 4, 6]
    var minutes = "min45"
    var places: Set<String> = ["home"]
    var equipment: Set<String> = []
    var timeOfDay = "flexible"
    var level = WorkoutHistorySummary.Level.beginner.rawValue
    var limitations = ""

    static let goalKeys = ["fitness", "strength", "weight", "endurance", "mobility"]
    static let minuteKeys = ["min20", "min30", "min45", "min60", "min90"]
    static let placeKeys = ["home", "gym", "outdoors", "pool"]
    static let equipmentKeys = ["pullupBar", "bands", "dumbbells", "kettlebell", "barbell", "mat"]
    static let timeKeys = ["morning", "noon", "evening", "flexible"]
    static let levelKeys = ["beginner", "intermediate", "advanced"]

    var isValid: Bool {
        !(goals.isEmpty && goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && !weekdays.isEmpty
    }

    private var orderedWeekdays: [Int] { LiftProgramPlanSheet.orderedWeekdays.filter(weekdays.contains) }

    private func chip(_ key: String) -> String { PlanFormat.t("zoop.planchat.chip.\(key)") }
    private func place(_ key: String) -> String { PlanFormat.t("zoop.planform.place.\(key)") }

    func answers() -> [PlanInterview.Slot: String] {
        let goalParts = Self.goalKeys.filter(goals.contains).map(chip) + [goalText]
        let horizon = openEnded ? chip("open")
            : PlanFormat.t("zoop.planform.horizon.answer", PlanFormat.day(TrainingPlan.dayKey(targetDate)))
        let days = PlanFormat.t("zoop.planchat.days.answer", "\(weekdays.count)",
                                orderedWeekdays.map(PlanFormat.shortWeekday).joined(separator: ", "))
        var session = [chip(minutes)]
        let places = Self.placeKeys.filter(self.places.contains).map(place)
        if !places.isEmpty { session.append(PlanFormat.t("zoop.planform.answer.where", places.joined(separator: ", "))) }
        let gear = Self.equipmentKeys.filter(equipment.contains).map(chip)
        if !gear.isEmpty { session.append(PlanFormat.t("zoop.planform.answer.equipment", gear.joined(separator: ", "))) }
        return [
            .goal: goalParts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", "),
            .horizon: horizon,
            .days: days,
            .session: session.joined(separator: " · "),
            .timeOfDay: chip(timeOfDay),
            .experience: chip(level),
            .limitations: limitations.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
    }

    /// The one line shown as the user's message once the form is sent.
    func summary() -> String {
        let a = answers()
        return [a[.goal], a[.days], a[.session]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// What the native routine form collects.
struct RoutineFormState: Equatable {
    var focus: Set<String> = ["fullBody"]
    var equipment: Set<String> = []
    var minutes = "min45"
    var level = WorkoutHistorySummary.Level.beginner.rawValue

    static let focusKeys = ["fullBody", "upper", "lower", "core"]
    static let equipmentKeys = ["noGear", "pullupBar", "bands", "dumbbells", "kettlebell", "barbell", "fullGym"]
    static let minuteKeys = ["min20", "min30", "min45", "min60"]

    var isValid: Bool { !focus.isEmpty && !equipment.isEmpty }

    private func chip(_ key: String) -> String { PlanFormat.t("zoop.planchat.chip.\(key)") }

    func answers() -> [PlanInterview.Slot: String] {
        [
            .focus: Self.focusKeys.filter(focus.contains).map(chip).joined(separator: ", "),
            .equipment: Self.equipmentKeys.filter(equipment.contains).map(chip).joined(separator: ", "),
            .duration: chip(minutes),
            .level: chip(level),
        ]
    }

    func summary() -> String {
        let a = answers()
        return [a[.focus], a[.equipment], a[.duration]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
