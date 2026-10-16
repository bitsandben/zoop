import Foundation
import StrandAnalytics
import StrandDesign
import StrandImport

/// What the plan / routine builder sends to the provider, outside the view and the model.
enum PlanChatPrompts {

    // MARK: Final requests

    /// The sports the plan may use, as catalogue names.
    static let planSports: [String] = [
        KnownWorkoutType.walking, .running, .hiking, .cycling, .indoorCycle, .poolSwim, .openWaterSwim,
        .rowing, .elliptical, .strength, .calisthenics, .hiit, .crossfit, .yoga, .pilates, .stretching, .boxing,
    ].map(\.rawValue)

    static var planSystem: String { TrainingPlanDraftParser.systemPrompt(sports: planSports) }

    static func planRequest(state: PlanInterview.State, history: WorkoutHistorySummary, today: Date) -> String {
        """
        Today is \(TrainingPlan.dayKey(today)) (\(englishWeekday(today))).
        The user's answers:
        \(state.answersBlock)
        Workout history: \(history.promptLine)
        Build the plan now.
        """
    }

    static func planEdit(_ draft: TrainingPlanDraft, change: String, today: Date) -> String {
        """
        Today is \(TrainingPlan.dayKey(today)). Current plan: \(TrainingPlanDraftParser.json(draft))
        The user wants this change: "\(change)"
        Return the full updated plan.
        """
    }

    static func routineRequest(state: PlanInterview.State) -> String {
        let a = state.answers
        let minutes = (a[.duration] ?? "").split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) } ?? 45
        let request = LiftRoutineGenerator.Request(
            goal: "\(a[.focus] ?? ""); experience: \(a[.level] ?? "")",
            equipment: a[.equipment] ?? "", minutes: minutes, focus: a[.focus] ?? "",
            language: CoachLanguage.code)
        return LiftRoutineGenerator.userPrompt(for: request)
    }

    static func routineEdit(_ program: ImportedProgram, change: String) -> String {
        let lines = program.lines.map { l in
            "\(l.exercise) \(l.targetSets ?? 3)x\(l.targetReps ?? 10)"
        }.joined(separator: ", ")
        return "Current routine \"\(program.name)\": \(lines).\nThe user wants this change: \"\(change)\"\nReturn the full updated routine."
    }

    static let jsonRetry = "That was not valid JSON for the schema. Reply with the JSON object only."

    private static func englishWeekday(_ date: Date) -> String {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US_POSIX")
        return c.weekdaySymbols[c.component(.weekday, from: date) - 1]
    }
}
