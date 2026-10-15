import Foundation
import WhoopStore
import StrandImport

/// Shared Lift Log program actions, used by the Lift Log screen and the training calendar so both
/// start a session and save a program the same way.
@MainActor
enum LiftProgramStarter {

    /// Flatten a program into the plan the session runs. The plan is SNAPSHOT at start: editing or
    /// deleting the program mid-session cannot change what is being tapped through.
    static func start(_ program: LiftProgramRow, repo: Repository, session: LiftSessionController) async {
        // Refuse to start a second session over a running one: two live sessions would both claim
        // the strap gesture and both write the in-flight snapshot.
        guard !session.isActive else {
            session.isPresented = true
            return
        }
        guard let store = await repo.storeHandle() else { return }
        let items = (try? await store.liftProgramItems(programId: program.id)) ?? []
        guard !items.isEmpty else { return }
        let vocabulary = (try? await store.liftExercises(deviceId: repo.deviceId)) ?? []

        let plan = items.map { item -> LiftPlanItem in
            // The classification comes from the exercise vocabulary, which is the one place that owns
            // it — the program line deliberately stores no muscle of its own to drift from.
            let known = vocabulary.first { $0.name == item.exercise }
            return LiftPlanItem(exercise: item.exercise,
                                primaryMuscle: known?.primaryMuscle,
                                secondaryMuscles: known?.secondaryMuscles ?? [],
                                targetSets: item.targetSets,
                                restSec: item.restSec,
                                targetRepsLow: item.targetRepsLow,
                                targetRepsHigh: item.targetRepsHigh,
                                targetRpe: item.targetRpe,
                                targetWeightKg: item.targetWeightKg,
                                note: item.note,
                                // Carried so a set added or dropped mid-session can be written back
                                // onto the line it came from, and be there next time.
                                programItemId: item.id)
        }
        // Progressive overload from the logged sets and today's muscle recovery, applied to this
        // session's snapshot only; the program's own targets stay as the user wrote them.
        let lines = await LiftProgressionAdvisor.lines(for: items, repo: repo)
        let adapted = LiftProgressionAdvisor.adapt(plan, lines: lines)
        guard !session.isActive else {
            session.isPresented = true
            return
        }
        session.start(plan: adapted, programId: program.id, programName: program.name)
    }

    /// Save a parsed program (generated or imported) as a new Lift Log program, remembering its
    /// exercises in the vocabulary. Returns the new program id, or nil when the store is unavailable.
    @discardableResult
    static func save(_ program: ImportedProgram, repo: Repository) async -> String? {
        guard let store = await repo.storeHandle() else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let programId = UUID().uuidString
        _ = try? await store.upsertLiftPrograms([LiftProgramRow(
            id: programId, deviceId: repo.deviceId, name: program.name, note: program.note,
            createdAt: now, updatedAt: now, archived: false)])

        let items = program.lines.enumerated().map { index, line in
            LiftProgramItemRow(
                id: UUID().uuidString, deviceId: repo.deviceId, programId: programId,
                ord: index, exercise: line.exercise,
                targetSets: line.targetSets,
                targetRepsLow: line.targetReps, targetRepsHigh: nil, targetRpe: line.targetMaxRpe,
                targetWeightKg: line.targetWeightKg,
                restSec: line.restSec, note: line.note)
        }
        _ = try? await store.replaceLiftProgramItems(programId: programId, items: items)

        // Best-effort: the vocabulary is capped, and hitting the cap must not fail the save.
        let exercises = program.lines.map { line in
            LiftExerciseRow(
                id: UUID().uuidString, deviceId: repo.deviceId, name: line.exercise,
                primaryMuscle: line.primaryMuscle,
                secondaryMuscles: line.secondaryMuscles,
                createdAt: now, lastUsedTs: nil)
        }
        _ = try? await store.upsertLiftExercises(exercises)
        return programId
    }
}
