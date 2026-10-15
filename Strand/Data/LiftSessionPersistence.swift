import Foundation
import WhoopStore

// Crash-safety for an in-flight gym session.
//
// A session is written to UserDefaults on every tap and rehydrated on launch. Mirrors
// `ActiveWorkoutPersistence`: a small `Codable` snapshot with unix-second anchors (absolute instants
// survive suspension, timezone changes and relaunch) and a pure encode/decode pair.

enum LiftSessionPersistence {

    /// The durable shape of an in-flight session: the minimum needed to rebuild the engine and finish.
    struct Snapshot: Codable, Equatable {
        var startSec: Int
        var programId: String?
        var programName: String?
        /// The plan, flattened at start, so editing the program mid-session cannot change what is run.
        var plan: [PlanItem]
        var stage: StageBox
        var sets: [RecordedSet]
        var stageStartedAt: Int
        /// Numbers typed into not-yet-performed sets, and slots marked warm-up in advance. Optional: an
        /// older snapshot decodes as absent and resumes with nothing pending.
        var pendingValues: [PendingValue]?
        var pendingWarmups: [SlotBox]?

        struct PendingValue: Codable, Equatable {
            var exerciseIndex: Int
            var setIndex: Int
            var weightKg: Double?
            var reps: Int?
            var rpe: Double?
        }

        struct SlotBox: Codable, Equatable {
            var exerciseIndex: Int
            var setIndex: Int
        }

        struct PlanItem: Codable, Equatable {
            var exercise: String
            var primaryMuscle: String?
            var secondaryMuscles: [String]
            var targetSets: Int
            var restSec: Int
            var targetRepsLow: Int?
            var targetRepsHigh: Int?
            var targetRpe: Double?
            var targetWeightKg: Double?
            var note: String?
            /// The program line this came from. Absent in older snapshots (decodes nil; skips write-back).
            var programItemId: String?
            /// True for a line added during the session. Absent in older snapshots (a program line).
            var addedInSession: Bool?
        }

        /// The stage as a flat record rather than an encoded enum, so adding a case is not a migration
        /// hazard and an older build decodes to "warm-up" rather than garbage.
        struct StageBox: Codable, Equatable {
            var kind: String        // warmup | working | resting | cooldown | finished
            var item: Int?
            var set: Int?
            var endsAt: Int?
        }

        struct RecordedSet: Codable, Equatable {
            var exerciseIndex: Int
            var setIndex: Int
            var weightKg: Double?
            var reps: Int?
            var rpe: Double?
            var isWarmup: Bool
            var startTs: Int
            var endTs: Int
            var restSec: Int?
        }
    }

    /// The single UserDefaults key (JSON-encoded `Snapshot`).
    static let defaultsKey = "zoop.activeLiftSession"

    // MARK: - Codec

    static func encode(_ snapshot: Snapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    /// Decodes a snapshot, bound-checking untrusted values. Nil for garbage/empty input or an
    /// implausible start time, so a corrupt write means "no session in flight".
    static func decode(_ data: Data?) -> Snapshot? {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode(Snapshot.self, from: data),
              raw.startSec > 1_000_000_000,                       // after 2001; not a zero/garbage anchor
              raw.startSec < Int(Date().timeIntervalSince1970) + 86_400,
              !raw.plan.isEmpty
        else { return nil }
        return raw
    }

    // MARK: - UserDefaults

    static func store(_ snapshot: Snapshot?, into d: UserDefaults = .standard) {
        guard let snapshot, let data = encode(snapshot) else {
            d.removeObject(forKey: defaultsKey)
            return
        }
        d.set(data, forKey: defaultsKey)
    }

    static func load(from d: UserDefaults = .standard) -> Snapshot? {
        decode(d.data(forKey: defaultsKey))
    }

    static func clear(_ d: UserDefaults = .standard) {
        d.removeObject(forKey: defaultsKey)
    }

    // MARK: - Engine bridge

    static func snapshot(engine: LiftSessionEngine,
                         programId: String?,
                         programName: String?,
                         pendingValues: [LiftSlot: LiftSessionController.PendingSetValues],
                         pendingWarmups: Set<LiftSlot>) -> Snapshot {
        Snapshot(
            startSec: engine.startTs,
            programId: programId,
            programName: programName,
            plan: engine.plan.map {
                Snapshot.PlanItem(exercise: $0.exercise,
                                  primaryMuscle: $0.primaryMuscle?.rawValue,
                                  secondaryMuscles: $0.secondaryMuscles.map(\.rawValue),
                                  targetSets: $0.targetSets,
                                  restSec: $0.restSec,
                                  targetRepsLow: $0.targetRepsLow,
                                  targetRepsHigh: $0.targetRepsHigh,
                                  targetRpe: $0.targetRpe,
                                  targetWeightKg: $0.targetWeightKg,
                                  note: $0.note,
                                  programItemId: $0.programItemId,
                                  // Written only when true, so a session nobody added to encodes as before.
                                  addedInSession: $0.addedInSession ? true : nil)
            },
            stage: box(engine.stage),
            sets: engine.sets.map {
                Snapshot.RecordedSet(exerciseIndex: $0.exerciseIndex, setIndex: $0.setIndex,
                                     weightKg: $0.weightKg, reps: $0.reps, rpe: $0.rpe,
                                     isWarmup: $0.isWarmup, startTs: $0.startTs, endTs: $0.endTs,
                                     restSec: $0.restSec)
            },
            stageStartedAt: engine.stageStartedAt,
            // Sorted so the encoding is stable and the defaults blob is not rewritten needlessly.
            pendingValues: pendingValues
                .sorted { ($0.key.exerciseIndex, $0.key.setIndex) < ($1.key.exerciseIndex, $1.key.setIndex) }
                .map { slot, values in
                    Snapshot.PendingValue(exerciseIndex: slot.exerciseIndex, setIndex: slot.setIndex,
                                          weightKg: values.weightKg, reps: values.reps, rpe: values.rpe)
                },
            pendingWarmups: pendingWarmups
                .sorted { ($0.exerciseIndex, $0.setIndex) < ($1.exerciseIndex, $1.setIndex) }
                .map { Snapshot.SlotBox(exerciseIndex: $0.exerciseIndex, setIndex: $0.setIndex) })
    }

    /// The numbers typed in advance, as the controller holds them.
    static func pendingValues(from s: Snapshot) -> [LiftSlot: LiftSessionController.PendingSetValues] {
        var out: [LiftSlot: LiftSessionController.PendingSetValues] = [:]
        for p in s.pendingValues ?? [] {
            out[LiftSlot(exerciseIndex: p.exerciseIndex, setIndex: p.setIndex)] =
                LiftSessionController.PendingSetValues(weightKg: p.weightKg, reps: p.reps, rpe: p.rpe)
        }
        return out
    }

    /// The warm-up marks made in advance, as the controller holds them.
    static func pendingWarmups(from s: Snapshot) -> Set<LiftSlot> {
        Set((s.pendingWarmups ?? []).map { LiftSlot(exerciseIndex: $0.exerciseIndex, setIndex: $0.setIndex) })
    }

    /// Rebuilds an engine from a snapshot. Unknown muscle tokens are dropped rather than failing the
    /// read (as `LiftMuscle.decodeList`), so a newer build's snapshot doesn't strand an older one.
    static func engine(from s: Snapshot) -> LiftSessionEngine {
        let plan = s.plan.map {
            LiftPlanItem(exercise: $0.exercise,
                         primaryMuscle: $0.primaryMuscle.flatMap(LiftMuscle.init(rawValue:)),
                         secondaryMuscles: $0.secondaryMuscles.compactMap(LiftMuscle.init(rawValue:)),
                         targetSets: $0.targetSets,
                         restSec: $0.restSec,
                         targetRepsLow: $0.targetRepsLow,
                         targetRepsHigh: $0.targetRepsHigh,
                         targetRpe: $0.targetRpe,
                         targetWeightKg: $0.targetWeightKg,
                         note: $0.note,
                         programItemId: $0.programItemId,
                         addedInSession: $0.addedInSession ?? false)
        }
        let sets = s.sets.map {
            LiftRecordedSet(exerciseIndex: $0.exerciseIndex, setIndex: $0.setIndex,
                            weightKg: $0.weightKg, reps: $0.reps, rpe: $0.rpe,
                            isWarmup: $0.isWarmup, startTs: $0.startTs, endTs: $0.endTs,
                            restSec: $0.restSec)
        }
        return LiftSessionEngine(restoring: plan, startTs: s.startSec,
                                 stage: unbox(s.stage), sets: sets, stageStartedAt: s.stageStartedAt)
    }

    private static func box(_ stage: LiftSessionEngine.Stage) -> Snapshot.StageBox {
        switch stage {
        case .warmup:
            return .init(kind: "warmup", item: nil, set: nil, endsAt: nil)
        case .working(let slot):
            return .init(kind: "working", item: slot.exerciseIndex, set: slot.setIndex, endsAt: nil)
        case .resting(let slot, let endsAt):
            return .init(kind: "resting", item: slot.exerciseIndex, set: slot.setIndex, endsAt: endsAt)
        case .finished:
            return .init(kind: "finished", item: nil, set: nil, endsAt: nil)
        }
    }

    /// Anything unrecognised (a box missing its indices, or the retired "cooldown" kind) falls back to
    /// the warm-up. Completed sets are carried in `sets` regardless, so only the cursor is forgotten.
    private static func unbox(_ box: Snapshot.StageBox) -> LiftSessionEngine.Stage {
        switch box.kind {
        case "working":
            guard let i = box.item, let s = box.set else { return .warmup }
            return .working(LiftSlot(exerciseIndex: i, setIndex: s))
        case "resting":
            guard let i = box.item, let s = box.set, let e = box.endsAt else { return .warmup }
            return .resting(LiftSlot(exerciseIndex: i, setIndex: s), endsAt: e)
        case "finished":
            return .finished
        default:
            return .warmup
        }
    }
}
