import Foundation
import StrandAnalytics
import WhoopStore

/// Reads the Lift Log for `LiftProgression`: the last two logged sessions of each exercise in a
/// routine, and today's muscle recovery. Read-only; the routine's stored targets are never rewritten,
/// the advice is applied to the session plan when a routine starts.
@MainActor
enum LiftProgressionAdvisor {

    struct Line: Equatable {
        let itemId: String
        let advice: LiftProgression.Advice?
        let recovery: LiftProgression.RecoveryAction
        /// The muscle group behind `recovery`, and how recovered it is.
        let group: MuscleLoad.Group?
        let percentRecovered: Int?
    }

    /// Advice per program line, in program order.
    static func lines(for items: [LiftProgramItemRow], repo: Repository, now: Date = Date()) async -> [Line] {
        guard let store = await repo.storeHandle(), !items.isEmpty else { return [] }
        let vocabulary = (try? await store.liftExercises(deviceId: repo.deviceId)) ?? []
        let nowTs = Int(now.timeIntervalSince1970)
        let sessions = (try? await store.liftSessions(deviceId: repo.deviceId, fromTs: nowTs - 365 * 86_400,
                                                      toTs: nowTs)) ?? []
        let startById = Dictionary(sessions.map { ($0.id, $0.startTs) }, uniquingKeysWith: max)

        let muscleLoad = await LiftFitnessSnapshot.load(repo: repo, hrMax: nil, now: now).muscleLoad
        var recovered: [MuscleLoad.Group: Int] = [:]
        for entry in muscleLoad?.entries ?? [] { recovered[entry.group] = entry.percentRecovered }

        var groups: [MuscleLoad.Group?] = []
        var advice: [LiftProgression.Advice?] = []
        for item in items {
            let muscle = vocabulary.first { $0.name == item.exercise }?.primaryMuscle
            let group = muscle.map(MuscleLoad.Group.init(lift:))
            groups.append(group)

            var history: [[LiftProgression.Performed]] = []
            var before: Int?
            for _ in 0..<2 {
                let sets = (try? await store.lastLiftSets(deviceId: repo.deviceId, exercise: item.exercise,
                                                          before: before)) ?? []
                guard let sessionId = sets.first?.sessionId, let start = startById[sessionId] else { break }
                history.insert(sets.filter { !$0.isWarmup }.map {
                    LiftProgression.Performed(reps: $0.reps, weightKg: $0.weightKg, rpe: $0.rpe)
                }, at: 0)
                before = start
            }
            let target = LiftProgression.Target(sets: max(1, item.targetSets ?? 3), repsLow: item.targetRepsLow,
                                                repsHigh: item.targetRepsHigh, weightKg: item.targetWeightKg)
            advice.append(LiftProgression.advise(target: target, sessions: history,
                                                 lowerBody: group?.region == .legs))
        }
        let actions = LiftProgression.recoveryActions(groups: groups, recovered: recovered)
        return items.indices.map { i in
            Line(itemId: items[i].id, advice: advice[i], recovery: actions[i], group: groups[i],
                 percentRecovered: groups[i].flatMap { recovered[$0] })
        }
    }

    /// The session plan with progression and today's recovery applied: skipped lines dropped (never
    /// all of them), reduced lines one set lighter, weights and reps from the advice.
    static func adapt(_ plan: [LiftPlanItem], lines: [Line]) -> [LiftPlanItem] {
        let byId = Dictionary(lines.map { ($0.itemId, $0) }, uniquingKeysWith: { a, _ in a })
        var adapted: [LiftPlanItem] = []
        for var item in plan {
            guard let id = item.programItemId, let line = byId[id] else { adapted.append(item); continue }
            if line.recovery == .skip { continue }
            if line.recovery == .reduceSet { item.targetSets = max(1, item.targetSets - 1) }
            if let next = line.advice?.next {
                if let w = next.weightKg { item.targetWeightKg = w }
                if let low = next.repsLow { item.targetRepsLow = low }
                if let high = next.repsHigh { item.targetRepsHigh = high }
            }
            adapted.append(item)
        }
        return adapted.isEmpty ? plan : adapted
    }
}
