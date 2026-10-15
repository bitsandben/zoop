import Foundation
import StrandAnalytics
import StrandDesign
import StrandImport

/// Everything the plan / routine builder says or sends, outside the view and the model: the prompts
/// for the provider, the template questions used when no reply arrives, and the quick replies.
enum PlanChatPrompts {

    // MARK: Interview turns

    static func interviewerSystem(_ kind: PlanInterview.Kind) -> String {
        let thing = kind == .plan ? "a weekly training plan" : "a single strength routine"
        return """
        You are Zoop's training coach running a short setup interview to build \(thing). Write ONE chat \
        message: acknowledge the user's last answer in a few words, then ask exactly ONE question about \
        the topic you are given. At most 2 short sentences and 200 characters in total. Warm and casual. \
        No markdown, no lists, no headings. Never ask about anything other than the given topic.
        """
    }

    static func interviewerTurn(state: PlanInterview.State, lastAnswer: String, next: PlanInterview.Slot,
                                history: WorkoutHistorySummary) -> String {
        var lines = ["Interview so far:", state.answersBlock,
                     "User's last answer: \"\(lastAnswer)\"",
                     "Next question topic: \(next.brief)"]
        if next == .experience || next == .level {
            lines.append("Their recent history, computed on the phone: \(history.promptLine) "
                + "Mention what you see in one short clause, then ask how experienced they are.")
        }
        return lines.joined(separator: "\n")
    }

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

    // MARK: Words shown in the sheet

    static func greeting(_ kind: PlanInterview.Kind, name: String) -> String {
        let first = name.split(separator: " ").first.map(String.init) ?? ""
        let base = kind == .plan ? "zoop.planchat.plan.greeting" : "zoop.planchat.routine.greeting"
        return first.isEmpty ? PlanFormat.t(base + ".anon") : PlanFormat.t(base, first)
    }

    /// The question asked when the provider gives no usable reply.
    static func template(_ slot: PlanInterview.Slot) -> String {
        PlanFormat.t("zoop.planchat.q.\(slot.rawValue)")
    }

    /// Quick replies per question; the experience chips lead with the level the history suggests.
    static func chips(_ slot: PlanInterview.Slot, history: WorkoutHistorySummary) -> [String] {
        let keys: [String]
        switch slot {
        case .goal: keys = ["fitness", "strength", "weight", "endurance", "mobility"]
        case .horizon: keys = ["open", "weeks8", "weeks12"]
        case .days: keys = []
        case .session: keys = ["home30", "gym45", "gym60", "outdoors"]
        case .timeOfDay: keys = ["morning", "noon", "evening", "flexible"]
        case .experience, .level:
            let order: [WorkoutHistorySummary.Level] = [.beginner, .intermediate, .advanced]
            let suggested = history.suggestedLevel
            keys = ([suggested] + order.filter { $0 != suggested }).map(\.rawValue)
        case .limitations: keys = ["none"]
        case .focus: keys = ["fullBody", "upper", "lower", "core"]
        case .equipment: keys = ["noGear", "pullupBar", "bands", "dumbbells", "fullGym"]
        case .duration: keys = ["min20", "min30", "min45", "min60"]
        }
        return keys.map { PlanFormat.t("zoop.planchat.chip.\($0)") }
    }
}
