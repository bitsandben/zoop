import Foundation
import WhoopStore

// The session state machine: the heart of the Lift Log.
//
// The plan is a SHEET of slots (every set of every exercise, all visible) and any pending slot can
// be started at any time: a gym is not a queue. PURE (no timers, store or SwiftUI), so it is
// testable with no strap or database. Time enters ONLY as a parameter, and rest is an ABSOLUTE end
// instant, never a decrementing counter, so a phone that sleeps through a rest wakes up truthful.
// There is no cool-down stage: warm-up and cool-down fall out of the timestamps.

/// One set of one exercise, a position on the sheet. `setIndex` is 1-based within its exercise.
struct LiftSlot: Hashable {
    var exerciseIndex: Int
    var setIndex: Int
}

/// One planned exercise line, flattened from a program for the session to run.
struct LiftPlanItem: Equatable {
    var exercise: String
    var primaryMuscle: LiftMuscle?
    var secondaryMuscles: [LiftMuscle]
    /// Planned working sets. Always >= 1, so the line can be tapped through.
    var targetSets: Int
    /// Intended rest after each set, in seconds.
    var restSec: Int
    var targetRepsLow: Int?
    var targetRepsHigh: Int?
    var targetRpe: Double?
    /// The weight the program plans, in kilograms.
    var targetWeightKg: Double?
    var note: String?
    /// The `liftProgramItem.id` this line came from, so a changed set count can be offered back to the
    /// program. Nil when no program line is behind it; an added line carries the id it will have.
    var programItemId: String?
    /// Added while the session ran (`LiftSessionEngine.addExercise`); finishing offers to add a line.
    var addedInSession: Bool

    /// Rest used when a program line does not specify one; only a starting value, since actual rest
    /// is measured from the taps.
    static let defaultRestSec = 120

    init(exercise: String,
         primaryMuscle: LiftMuscle? = nil,
         secondaryMuscles: [LiftMuscle] = [],
         targetSets: Int? = nil,
         restSec: Int? = nil,
         targetRepsLow: Int? = nil,
         targetRepsHigh: Int? = nil,
         targetRpe: Double? = nil,
         targetWeightKg: Double? = nil,
         note: String? = nil,
         programItemId: String? = nil,
         addedInSession: Bool = false) {
        self.exercise = exercise
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscles = secondaryMuscles
        self.targetSets = max(1, targetSets ?? 1)
        self.restSec = max(0, restSec ?? LiftPlanItem.defaultRestSec)
        self.targetRepsLow = targetRepsLow
        self.targetRepsHigh = targetRepsHigh
        self.targetRpe = targetRpe
        self.targetWeightKg = targetWeightKg
        self.note = note
        self.programItemId = programItemId
        self.addedInSession = addedInSession
    }
}

/// One set as actually performed.
struct LiftRecordedSet: Equatable {
    var exerciseIndex: Int
    var setIndex: Int
    var weightKg: Double?
    var reps: Int?
    var rpe: Double?
    var isWarmup: Bool
    var startTs: Int
    var endTs: Int
    /// Rest actually taken after this set. Nil while running, or when the user moved on without resting.
    var restSec: Int?

    var slot: LiftSlot { LiftSlot(exerciseIndex: exerciseIndex, setIndex: setIndex) }
}

/// The numbers a set shows in grey: what it would save if completed with nothing typed. Weight and
/// reps only; RPE is deliberately absent (see `carry(for:lastSession:)`).
struct LiftSetCarry: Equatable {
    var weightKg: Double?
    var reps: Int?

    static let none = LiftSetCarry(weightKg: nil, reps: nil)
}

struct LiftSessionEngine: Equatable {

    enum Stage: Equatable {
        /// Before the first set — the warm-up.
        case warmup
        /// Performing a set.
        case working(LiftSlot)
        /// Resting after a set. `endsAt` is an absolute unix second.
        case resting(LiftSlot, endsAt: Int)
        /// Ended; ready to save.
        case finished
    }

    /// The lines being worked. Mutable only in set count per line and by appending a line; nothing else
    /// about a line changes mid-session.
    private(set) var plan: [LiftPlanItem]
    /// When the session began (unix seconds).
    let startTs: Int
    private(set) var stage: Stage
    /// Completed sets in COMPLETION order (the order they happened), which `ord` is written from.
    private(set) var sets: [LiftRecordedSet]
    /// When the current stage began, so a set's duration is measurable.
    private(set) var stageStartedAt: Int

    /// Undo stack of whole-state snapshots rather than inverse operations, which cannot get the
    /// arithmetic wrong.
    private var history: [Snapshot] = []

    /// The plan travels in the snapshot: once the set count can move, a stage is only meaningful under
    /// the count it was saved with, so undo cannot leave the session on a slot the sheet no longer draws.
    private struct Snapshot: Equatable {
        var plan: [LiftPlanItem]
        var stage: Stage
        var sets: [LiftRecordedSet]
        var stageStartedAt: Int
    }

    init(plan: [LiftPlanItem], startTs: Int) {
        self.plan = plan
        self.startTs = startTs
        self.stage = .warmup
        self.sets = []
        self.stageStartedAt = startTs
    }

    /// Rebuilds an interrupted session (see `LiftSessionPersistence`). Undo history is deliberately
    /// NOT restored.
    init(restoring plan: [LiftPlanItem], startTs: Int, stage: Stage,
         sets: [LiftRecordedSet], stageStartedAt: Int) {
        self.plan = plan
        self.startTs = startTs
        self.stage = stage
        self.sets = sets
        self.stageStartedAt = stageStartedAt
    }

    // MARK: - The sheet

    /// Every slot of one exercise, in order.
    func slots(forExercise index: Int) -> [LiftSlot] {
        guard plan.indices.contains(index) else { return [] }
        return (1...plan[index].targetSets).map { LiftSlot(exerciseIndex: index, setIndex: $0) }
    }

    /// Every slot in the whole session, in plan order.
    var allSlots: [LiftSlot] { plan.indices.flatMap { slots(forExercise: $0) } }

    func recordedSet(for slot: LiftSlot) -> LiftRecordedSet? {
        sets.first { $0.slot == slot }
    }

    func isCompleted(_ slot: LiftSlot) -> Bool { recordedSet(for: slot) != nil }

    /// The slot being worked or rested from.
    var currentSlot: LiftSlot? {
        switch stage {
        case .working(let s): return s
        case .resting(let s, _): return s
        case .warmup, .finished: return nil
        }
    }

    /// The next slot the plan would suggest: the first uncompleted one in plan order, nil when the
    /// sheet is done. Not what `advance` follows after a set (see `slotAfter(_:)`).
    var nextPendingSlot: LiftSlot? {
        allSlots.first { !isCompleted($0) }
    }

    /// Where the session goes after finishing `slot`: the next uncompleted set of the SAME exercise,
    /// and only once that is finished, the first uncompleted slot in plan order. Plan order alone would
    /// throw a user who skipped exercise 1 back to it after every set of exercise 3.
    func slotAfter(_ slot: LiftSlot) -> LiftSlot? {
        slots(forExercise: slot.exerciseIndex).first { !isCompleted($0) } ?? nextPendingSlot
    }

    /// The set the session is heading to after the current one (what the bar and Lock Screen call
    /// "next"): `advance`'s target, with the current set counted as done. Never a rest. Nil when
    /// nothing is left.
    var upcomingSlot: LiftSlot? {
        switch stage {
        case .warmup:
            return nextPendingSlot
        case .working(let slot), .resting(let slot, _):
            return slots(forExercise: slot.exerciseIndex).first { !isCompleted($0) && $0 != slot }
                ?? allSlots.first { !isCompleted($0) && $0 != slot }
        case .finished:
            return nil
        }
    }

    var allCompleted: Bool { nextPendingSlot == nil }
    var isFinished: Bool { stage == .finished }
    var canUndo: Bool { !history.isEmpty }

    var plannedWorkingSets: Int { plan.reduce(0) { $0 + $1.targetSets } }
    var completedWorkingSets: Int { sets.filter { !$0.isWarmup }.count }

    func planItem(for slot: LiftSlot) -> LiftPlanItem? {
        plan.indices.contains(slot.exerciseIndex) ? plan[slot.exerciseIndex] : nil
    }

    /// Seconds left in the current rest, floored at zero (an overrun rest reads "0:00"). Nil when not resting.
    func restRemaining(now: Int) -> Int? {
        guard case .resting(_, let endsAt) = stage else { return nil }
        return max(0, endsAt - now)
    }

    /// The nearest earlier set of this exercise already performed in THIS session, or nil.
    func previousSetInSession(for slot: LiftSlot) -> LiftRecordedSet? {
        (1..<max(1, slot.setIndex)).reversed()
            .compactMap { recordedSet(for: LiftSlot(exerciseIndex: slot.exerciseIndex, setIndex: $0)) }
            .first
    }

    /// The numbers a slot shows in grey, in order of preference: this exercise earlier in THIS session
    /// (by what that set counts as, `values(of:lastSession:)`), the same set number LAST session, then
    /// the program's target.
    ///
    /// Grey stays grey: finishing a set records timing only, and a number becomes the set's own only
    /// when typed. What untyped sets are worth is decided once at finish (`setsToSave`).
    ///
    /// RPE is NOT carried: it is how hard a set FELT, knowable only afterwards, and carrying it would
    /// make every set read as rated and corrupt the RPE card's coverage. `lastSession` is supplied by
    /// the caller; a set number it lacks falls through to the target.
    func carry(for slot: LiftSlot, lastSession: [Int: LiftSetCarry]) -> LiftSetCarry {
        let previous = previousSetInSession(for: slot).map { values(of: $0.slot, lastSession: lastSession) }
        let last = lastSession[slot.setIndex]
        let item = planItem(for: slot)
        return LiftSetCarry(
            weightKg: previous?.weightKg ?? last?.weightKg ?? item?.targetWeightKg,
            reps: previous?.reps ?? last?.reps ?? item?.targetRepsLow)
    }

    /// What a slot counts as: each number typed into it, else its grey number.
    func values(of slot: LiftSlot, lastSession: [Int: LiftSetCarry]) -> LiftSetCarry {
        let grey = carry(for: slot, lastSession: lastSession)
        guard let set = recordedSet(for: slot) else { return grey }
        return LiftSetCarry(weightKg: set.weightKg ?? grey.weightKg, reps: set.reps ?? grey.reps)
    }

    /// Slots never performed. Finishing asks once what happens to all of them; a performed set is
    /// complete whether or not anything was typed.
    var unperformedSlots: [LiftSlot] {
        allSlots.filter { !isCompleted($0) }
    }

    // MARK: - Actions

    /// Begins a specific set from any stage, so a busy machine never blocks the session. Starting a
    /// set while ANOTHER is in progress abandons it unrecorded; starting a completed slot re-opens it
    /// for a redo, dropping its previous record.
    mutating func start(_ slot: LiftSlot, now: Int) {
        guard planItem(for: slot) != nil else { return }
        pushHistory()
        sets.removeAll { $0.slot == slot }
        stage = .working(slot)
        stageStartedAt = now
    }

    /// The big button. Context decides what it means.
    mutating func advance(now: Int) {
        switch stage {
        case .warmup:
            guard let next = nextPendingSlot else { return }
            start(next, now: now)

        case .working(let slot):
            pushHistory()
            // Timing only; numbers stay grey until typed.
            sets.append(LiftRecordedSet(
                exerciseIndex: slot.exerciseIndex, setIndex: slot.setIndex,
                weightKg: nil, reps: nil, rpe: nil, isWarmup: false,
                startTs: stageStartedAt, endTs: now, restSec: nil))
            let rest = planItem(for: slot)?.restSec ?? LiftPlanItem.defaultRestSec
            stage = .resting(slot, endsAt: now + rest)
            stageStartedAt = now

        case .resting(let slot, _):
            pushHistory()
            // Record what was ACTUALLY rested: only the taps can know.
            if let i = sets.firstIndex(where: { $0.slot == slot }) {
                sets[i].restSec = max(0, now - stageStartedAt)
            }
            if let next = slotAfter(slot) {
                stage = .working(next)
                stageStartedAt = now
            } else {
                // Sheet complete: stay put; the time until the user finishes is the cool-down.
                stage = .resting(slot, endsAt: now)
                stageStartedAt = now
            }

        case .finished:
            break
        }
    }

    /// Fills in or corrects what a set actually was. Editing only (never appends); no-op for a slot
    /// not yet completed.
    mutating func updateSet(_ slot: LiftSlot,
                            weightKg: Double?, reps: Int?, rpe: Double?, isWarmup: Bool) {
        guard let i = sets.firstIndex(where: { $0.slot == slot }) else { return }
        sets[i].weightKg = weightKg
        sets[i].reps = reps
        sets[i].rpe = rpe
        sets[i].isWarmup = isWarmup
    }

    // MARK: - Changing how many sets a line holds

    /// The most sets one line may hold: a bound against a stuck finger, as each set is a sheet row and
    /// a crash-snapshot slot.
    static let maxSetsPerExercise = 20

    /// Appends one set to an exercise's line. Returns false when the line is at the bound.
    @discardableResult
    mutating func addSet(toExercise index: Int) -> Bool {
        guard plan.indices.contains(index),
              plan[index].targetSets < LiftSessionEngine.maxSetsPerExercise else { return false }
        pushHistory()
        plan[index].targetSets += 1
        return true
    }

    /// Whether the last set of a line can be dropped. Only the LAST one, and only while pending: set
    /// numbers are positions, so removing from the middle would re-label recorded sets, and a completed
    /// set is data. The set being worked or rested from is excluded too.
    func canRemoveSet(fromExercise index: Int) -> Bool {
        guard plan.indices.contains(index), plan[index].targetSets > 1 else { return false }
        let last = LiftSlot(exerciseIndex: index, setIndex: plan[index].targetSets)
        return !isCompleted(last) && currentSlot != last
    }

    /// Drops the last (pending) set of an exercise's line. Returns false when the rule above says no.
    @discardableResult
    mutating func removeSet(fromExercise index: Int) -> Bool {
        guard canRemoveSet(fromExercise: index) else { return false }
        pushHistory()
        plan[index].targetSets -= 1
        return true
    }

    // MARK: - Adding an exercise

    /// The most lines one session may hold: the importer's cap on a program, which the per-change
    /// crash snapshot was sized for.
    static let maxExercises = 200

    /// Appends an exercise the program does not have, as ONE set at the end of the sheet (any count the
    /// caller gives is ignored). Undoable. Returns false when finished or at `maxExercises`.
    @discardableResult
    mutating func addExercise(_ item: LiftPlanItem) -> Bool {
        guard stage != .finished, plan.count < LiftSessionEngine.maxExercises else { return false }
        pushHistory()
        var line = item
        line.targetSets = 1
        plan.append(line)
        return true
    }

    /// Ends the session, closing out the running rest first so its measured duration is kept.
    mutating func finish(now: Int) {
        guard stage != .finished else { return }
        pushHistory()
        if case .resting(let slot, _) = stage,
           let i = sets.firstIndex(where: { $0.slot == slot }), sets[i].restSec == nil {
            sets[i].restSec = max(0, now - stageStartedAt)
        }
        stage = .finished
        stageStartedAt = now
    }

    mutating func undo() {
        guard let previous = history.popLast() else { return }
        plan = previous.plan
        stage = previous.stage
        sets = previous.sets
        stageStartedAt = previous.stageStartedAt
    }

    private mutating func pushHistory() {
        history.append(Snapshot(plan: plan, stage: stage,
                                sets: sets, stageStartedAt: stageStartedAt))
    }
}
