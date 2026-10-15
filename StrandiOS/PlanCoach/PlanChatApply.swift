import Foundation
import StrandAnalytics
import StrandDesign
import StrandImport
import WhoopStore

/// "Übernehmen": writes an accepted draft into the app. Strength sessions with exercises become Lift
/// Log routines; the whole week goes into `TrainingPlan` (calendar, weekly review) with an undo entry.
@MainActor
enum PlanChatApply {

    static func apply(_ draft: TrainingPlanDraft, repo: Repository) async {
        var sessions: [PlanSession] = []
        for s in draft.sessions {
            var programId: String?
            if let program = s.program {
                var named = program
                named.name = s.title
                programId = await LiftProgramStarter.save(named, repo: repo)
            }
            sessions.append(PlanSession(id: UUID().uuidString, weekday: s.weekday, title: s.title,
                                        sport: s.sport, minutes: s.minutes, time: s.time, programId: programId))
        }
        var plan = TrainingPlanStore.plan
        plan.sessions = sessions
        plan.meta = TrainingPlan.Meta(name: draft.name, focus: draft.focus, kind: draft.kind.rawValue,
                                      startDay: draft.startDay, targetDay: draft.targetDay)
        plan.syncProgramWeekdays()
        TrainingPlanStore.save(plan, label: PlanFormat.t("zoop.plan.history.created"))
        // A new plan starts clean: no stale update, no review before its first full week.
        TrainingPlanStore.pending = nil
        UserDefaults.standard.set(PlanReviewRunner.weekKey(for: Date()), forKey: TrainingPlanStore.reviewedWeekKey)
    }

    static func apply(_ program: ImportedProgram, repo: Repository) async {
        await LiftProgramStarter.save(program, repo: repo)
    }

    /// The local workout history as the provider may see it: sports, counts and typical length only.
    static func historySummary(repo: Repository) async -> WorkoutHistorySummary {
        let rows = await repo.workoutRows(days: 90)
        return WorkoutHistorySummary.make(
            sessions: rows.map { .init(sport: KnownWorkoutTypeLookup.canonical($0.sport) ?? $0.sport,
                                       durationS: $0.durationS,
                                       startTs: $0.startTs) },
            now: Date(),
            isStrength: { sport in
                switch KnownWorkoutType.resolving(sport) {
                case .strength, .bodybuilding, .weightlifting, .crossfit, .calisthenics: return true
                default: return false
                }
            })
    }
}
