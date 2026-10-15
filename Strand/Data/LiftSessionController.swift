import Foundation
import Combine
import WhoopStore
import StrandAnalytics

// The live session, owned ABOVE any screen.
//
// The session outlives whichever sheet or bar displays it: this controller owns the engine, the
// rest timers, buzz gating and persistence, and the strap double-tap is claimed for the session's
// lifetime (handed back untouched at the end). Dismissing a view changes nothing about the session.

@MainActor
final class LiftSessionController: ObservableObject {

    /// The running session, or nil. Every change re-arms the rest timers (`scheduleRestTimers`).
    @Published private(set) var engine: LiftSessionEngine? { didSet { scheduleRestTimers() } }
    @Published private(set) var programId: String?
    @Published private(set) var programName: String?
    /// True while the full sheet is presented; false when minimised to the bottom bar.
    @Published var isPresented = false

    /// Bumped each time a finished session is written, so the sessions list can reload.
    @Published private(set) var savedSessions = 0

    /// Sends once a strap double-tap has moved the session on, with the new stage in place (unlike
    /// `$engine`, which publishes before the change lands). Lights the Lock Screen banner on that step.
    let strapStepTaken = PassthroughSubject<Void, Never>()

    /// Fires once any change to the session has landed and settled (debounced), which is what the Lock
    /// Screen banner follows. `objectWillChange` fires BEFORE the change lands.
    private(set) lazy var changesSettled: AnyPublisher<Void, Never> = objectWillChange
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .map { _ in () }
        .eraseToAnyPublisher()

    var isActive: Bool { engine != nil && engine?.isFinished == false }

    /// Rest period the five-second warning already fired for. Held here so re-opening the sheet
    /// mid-rest cannot re-fire it.
    private var warnedFor: Int?

    /// Slots marked as warm-up BEFORE being performed. An unperformed set has no record to carry the
    /// flag, so the mark is held here and applied when the set is recorded.
    @Published private(set) var pendingWarmups: Set<LiftSlot> = []

    /// Numbers typed into a set BEFORE it was performed. Typing must never append a set (an
    /// unperformed set would become data), so values are held here, shown on the row, and applied when
    /// the set is recorded, where they beat the carried plan.
    @Published private(set) var pendingValues: [LiftSlot: PendingSetValues] = [:]

    /// What a user typed into a set that has not happened yet; all optional.
    struct PendingSetValues: Equatable {
        var weightKg: Double?
        var reps: Int?
        var rpe: Double?

        var isEmpty: Bool { weightKg == nil && reps == nil && rpe == nil }
    }

    /// What the store holds for each exercise LAST session, by exercise name then set number: the
    /// middle layer of `LiftSessionEngine.carry(for:lastSession:)`. Held here so the bar and Lock Screen
    /// show the same grey numbers as the sheet; until loaded they fall through to the program target.
    @Published private var lastSession: [String: [Int: LiftSetCarry]] = [:]
    /// The running rest's warning and end, and the end they were set for (see `scheduleRestTimers`).
    private var restTimers: [Task<Void, Never>] = []
    private var scheduledRestEnd: Int?

    /// Fires the strap buzz. Injected so the controller has no BLE dependency.
    private let buzz: (UInt8) -> Void
    /// Claims/releases the strap's double-tap for the session's lifetime.
    private let setStrapHandler: ((@MainActor () -> Void)?) -> Void
    /// Writes a line to the strap log, accounting for a double-tap the session holds back.
    private let log: (String) -> Void

    /// When the session last acted on a strap double-tap (unix seconds); nil until it has, and after a
    /// relaunch.
    private var lastStrapStepAt: Int?

    /// One pulse confirms a strap double-tap registered; three means the rest is nearly up. The
    /// patterns must not be mistakable on a knocked-about wrist.
    static let advanceConfirmBuzzes: UInt8 = 1
    static let restWarningBuzzes: UInt8 = 3
    /// How long before the rest ends the warning fires.
    static let restWarningLeadSec = 5
    /// A strap double-tap this soon after the last one acted on is taken as a knock (see `isKnock`).
    static let strapKnockWindowSec = 5

    init(buzz: @escaping (UInt8) -> Void,
         setStrapHandler: @escaping ((@MainActor () -> Void)?) -> Void,
         log: @escaping (String) -> Void = { _ in }) {
        self.buzz = buzz
        self.setStrapHandler = setStrapHandler
        self.log = log
    }

    // MARK: - Lifecycle

    func start(plan: [LiftPlanItem], programId: String?, programName: String?) {
        let stamp = Int(Date().timeIntervalSince1970)
        engine = LiftSessionEngine(plan: plan, startTs: stamp)
        self.programId = programId
        self.programName = programName
        warnedFor = nil
        isPresented = true
        claimStrap()
        persist()
    }

    /// Picks up the session a previous run left going, as the app process starts. iOS relaunches Zoop
    /// in the background when the strap sends something; resuming before any screen exists means the
    /// Lock Screen banner iOS kept is picked up instead of ended. Logs the restart for strap logs.
    func resumeSaved(from defaults: UserDefaults = .standard) {
        guard !isActive, let snapshot = LiftSessionPersistence.load(from: defaults) else { return }
        resume(from: snapshot)
        log("Lift Log: session picked up again after Zoop restarted")
    }

    /// Rehydrates an interrupted session found on disk. Does NOT present the sheet; it returns as the
    /// bottom bar.
    func resume(from snapshot: LiftSessionPersistence.Snapshot, present: Bool = false) {
        engine = LiftSessionPersistence.engine(from: snapshot)
        programId = snapshot.programId
        programName = snapshot.programName
        // Pending numbers and pre-marked warm-ups come back too: they are expressed intent.
        pendingValues = LiftSessionPersistence.pendingValues(from: snapshot)
        pendingWarmups = LiftSessionPersistence.pendingWarmups(from: snapshot)
        // Suppress the warning for a rest already inside its final seconds, so reopening mid-rest does
        // not buzz three times.
        if case .resting(_, let endsAt) = engine?.stage,
           endsAt - Self.unixNow <= LiftSessionController.restWarningLeadSec {
            warnedFor = endsAt
        } else {
            warnedFor = nil
        }
        isPresented = present
        claimStrap()
    }

    /// Gives up the session without saving.
    func discard() {
        teardown()
        LiftSessionPersistence.clear()
    }

    /// Called once the session has been written to the store.
    func finishedSaving() {
        teardown()
        LiftSessionPersistence.clear()
        savedSessions += 1
    }

    private func teardown() {
        engine = nil
        programId = nil
        programName = nil
        warnedFor = nil
        lastStrapStepAt = nil
        pendingWarmups = []
        pendingValues = [:]
        isPresented = false
        setStrapHandler(nil)
    }

    /// The handler runs SYNCHRONOUSLY inside the frame handling that delivered the tap. Hopping through
    /// a `Task` let the triggered sync reach the strap first, delaying the confirming buzz by 1-2.8 s.
    private func claimStrap() {
        setStrapHandler({ [weak self] in self?.advance(fromStrap: true) })
    }

    /// The current unix second.
    static var unixNow: Int { Int(Date().timeIntervalSince1970) }

    // MARK: - Actions

    /// The one action. `fromStrap` earns a single confirming buzz, unless the tap reads as a knock.
    func advance(fromStrap: Bool = false) {
        guard let current = engine else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        if fromStrap {
            if let last = lastStrapStepAt,
               Self.isKnock(secondsSinceLastStep: stamp - last, stage: current.stage, now: stamp) {
                // No buzz: the missing confirmation is the lifter's cue to tap again.
                log("Lift Log: that double-tap was not acted on — \(stamp - last) s after the last one it "
                    + "acted on (under \(Self.strapKnockWindowSec) s is taken as a knock)")
                return
            }
            lastStrapStepAt = stamp
            // BUZZ FIRST, before state work: the confirmation is a latency signal and must not queue behind
            // a JSON encode and a defaults write.
            buzz(LiftSessionController.advanceConfirmBuzzes)
        }

        engine?.advance(now: stamp)
        // Straight after the stage moves, so the screen lights with no wait behind the bookkeeping below.
        if fromStrap { strapStepTaken.send() }
        applyPendingInput()
        warnedFor = nil
        persist()
    }

    /// Whether a strap double-tap `secondsSinceLastStep` after the last acted-on one is a knock rather
    /// than a tap. Detections shortly after a set started were the arm going onto the bar, not a second
    /// tap. Under `strapKnockWindowSec` counts as a knock, because no deliberate set or rest is that
    /// short; the exception is a rest already over (no rest planned, or all sets done), where going
    /// straight on is the plan. The on-screen button is never held back. A held-back tap gets no buzz,
    /// which tells the lifter to tap again.
    static func isKnock(secondsSinceLastStep: Int, stage: LiftSessionEngine.Stage, now: Int) -> Bool {
        guard (0..<strapKnockWindowSec).contains(secondsSinceLastStep) else { return false }
        if case .resting(_, let endsAt) = stage, endsAt <= now { return false }
        return true
    }

    // MARK: - Presentation
    //
    // What a running session looks like, resolved ONCE so the minimised bar and the Lock Screen
    // Live Activity agree on state, exercise, numbers and clock, including wording.

    struct Presentation: Equatable {
        var isResting: Bool
        /// The exercise being worked or rested from; the program's name during the warm-up.
        var exercise: String
        /// "Set 2", "Resting after set 2", "Ready for the next set", "Warm-up".
        var status: String
        /// "8 x 30 kg", already unit-converted. Nil when neither reps nor weight is known.
        var detail: String?
        /// "Next: Set 3 · Bench press" — see `nextLine(_:)`.
        var next: String
        var stageStartedAt: Date
        /// When the running rest is due to end. Nil while working.
        var restEndsAt: Date?
    }

    func presentation(system: UnitSystem) -> Presentation? {
        guard let engine, !engine.isFinished else { return nil }
        let started = Date(timeIntervalSince1970: TimeInterval(engine.stageStartedAt))
        let next = Self.nextLine(engine)

        guard let slot = engine.currentSlot, let item = engine.planItem(for: slot) else {
            return Presentation(isResting: false,
                                exercise: programName ?? String(localized: "Session"),
                                status: String(localized: "Warm-up"), detail: nil, next: next,
                                stageStartedAt: started, restEndsAt: nil)
        }

        let detail = setNumbers(for: slot, system: system)
        switch engine.stage {
        case .resting(_, let endsAt):
            let ready = endsAt <= Self.unixNow
            return Presentation(
                isResting: true, exercise: item.exercise,
                status: ready ? String(localized: "Ready for the next set")
                              : String(localized: "Resting after set \(slot.setIndex)"),
                detail: detail, next: next,
                stageStartedAt: started,
                restEndsAt: Date(timeIntervalSince1970: TimeInterval(endsAt)))
        default:
            return Presentation(
                isResting: false, exercise: item.exercise,
                status: String(localized: "Set \(slot.setIndex)"),
                detail: detail, next: next,
                stageStartedAt: started, restEndsAt: nil)
        }
    }

    /// The set after this one, on one line for the bar and Lock Screen. Always a SET, never the rest;
    /// the set number precedes the exercise so a narrow line cuts the name. "Last set" while the final
    /// set is worked; "All sets done" once it is.
    static func nextLine(_ engine: LiftSessionEngine) -> String {
        if let upcoming = engine.upcomingSlot, let item = engine.planItem(for: upcoming) {
            return String(localized: "Next: Set \(upcoming.setIndex) · \(item.exercise)")
        }
        return engine.allCompleted ? String(localized: "All sets done") : String(localized: "Last set")
    }

    /// Reps x weight for a slot, as "8 x 30 kg": typed numbers, else the grey ones, including numbers
    /// typed before the set is recorded (`pendingValues`), so the bar matches the sheet row.
    func setNumbers(for slot: LiftSlot, system: UnitSystem) -> String? {
        guard engine != nil else { return nil }
        let grey = values(of: slot)
        let typed = pendingValues[slot]
        let shown = LiftSetCarry(weightKg: typed?.weightKg ?? grey.weightKg, reps: typed?.reps ?? grey.reps)

        let weight = shown.weightKg.map {
            LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: system))
            + " " + LiftFormat.weightUnit(system)
        }
        switch (shown.reps, weight) {
        case (let r?, let w?): return "\(r) x \(w)"
        case (let r?, nil):    return String(localized: "\(r) reps")
        case (nil, let w?):    return w
        case (nil, nil):       return nil
        }
    }

    /// Hands over what the store knows about previous sessions; safe to call again on reload.
    func setLastSession(_ values: [String: [Int: LiftSetCarry]]) {
        lastSession = values
    }

    /// The grey numbers a slot shows: the single chain every surface reads so they cannot disagree.
    func carry(for slot: LiftSlot) -> LiftSetCarry {
        engine?.carry(for: slot, lastSession: lastSessionSets(for: slot)) ?? .none
    }

    /// What a slot counts as: typed numbers, else its grey ones.
    func values(of slot: LiftSlot) -> LiftSetCarry {
        engine?.values(of: slot, lastSession: lastSessionSets(for: slot)) ?? .none
    }

    private func lastSessionSets(for slot: LiftSlot) -> [Int: LiftSetCarry] {
        engine?.planItem(for: slot).flatMap { lastSession[$0.exercise] } ?? [:]
    }

    /// Marks a slot as a warm-up (or not): applies now if the set exists, else remembered for later.
    func setWarmup(_ slot: LiftSlot, _ isWarmup: Bool) {
        if isWarmup { pendingWarmups.insert(slot) } else { pendingWarmups.remove(slot) }
        if let row = engine?.recordedSet(for: slot) {
            engine?.updateSet(slot, weightKg: row.weightKg, reps: row.reps,
                              rpe: row.rpe, isWarmup: isWarmup)
        }
        persist()
    }

    func isWarmup(_ slot: LiftSlot) -> Bool {
        if let row = engine?.recordedSet(for: slot) { return row.isWarmup }
        return pendingWarmups.contains(slot)
    }

    /// Carries a pre-marked warm-up and any numbers typed in advance onto the set just recorded; a
    /// field left untouched stays grey. The entry is CONSUMED so a redo shows the ghosts again.
    private func applyPendingInput() {
        guard let engine, let last = engine.sets.last else { return }
        let typed = pendingValues.removeValue(forKey: last.slot)
        let warmup = last.isWarmup || pendingWarmups.contains(last.slot)
        guard typed != nil || warmup != last.isWarmup else { return }
        self.engine?.updateSet(last.slot,
                               weightKg: typed?.weightKg ?? last.weightKg,
                               reps: typed?.reps ?? last.reps,
                               rpe: typed?.rpe ?? last.rpe,
                               isWarmup: warmup)
    }

    /// Begins a specific set (out-of-order, e.g. a machine is occupied).
    func start(_ slot: LiftSlot, fromStrap: Bool = false) {
        guard engine != nil else { return }
        if fromStrap { buzz(LiftSessionController.advanceConfirmBuzzes) }
        let stamp = Int(Date().timeIntervalSince1970)
        engine?.start(slot, now: stamp)
        // Starting a slot drops its record, so its warm-up mark reverts to pending, where it already lives.
        warnedFor = nil
        persist()
    }

    /// Adds one set to an exercise. Returns whether anything changed (whether the program needs rewriting).
    @discardableResult
    func addSet(toExercise index: Int) -> Bool {
        guard engine?.addSet(toExercise: index) == true else { return false }
        persist()
        return true
    }

    /// Adds an exercise the program does not have, at the end: one set planned as 0 kg x 0 reps with
    /// the default rest, showing last session's numbers if any. Carries the id its program line will
    /// have if finishing adds it. Returns whether it was added.
    @discardableResult
    func addExercise(_ name: String, primaryMuscle: LiftMuscle?, secondaryMuscles: [LiftMuscle]) -> Bool {
        let line = LiftPlanItem(exercise: name, primaryMuscle: primaryMuscle,
                                secondaryMuscles: secondaryMuscles.filter { $0 != primaryMuscle },
                                targetSets: 1, targetRepsLow: 0, targetWeightKg: 0,
                                programItemId: UUID().uuidString, addedInSession: true)
        guard engine?.addExercise(line) == true else { return false }
        persist()
        return true
    }

    /// Drops the last pending set of an exercise; a completed set is never removed (see
    /// `LiftSessionEngine.canRemoveSet(fromExercise:)`).
    @discardableResult
    func removeSet(fromExercise index: Int) -> Bool {
        guard let engine, engine.canRemoveSet(fromExercise: index) else { return false }
        let dropped = LiftSlot(exerciseIndex: index, setIndex: engine.plan[index].targetSets)
        self.engine?.removeSet(fromExercise: index)
        // A removed slot must not keep a warm-up mark or typed numbers, or re-adding it would resurrect them.
        pendingWarmups.remove(dropped)
        pendingValues.removeValue(forKey: dropped)
        persist()
        return true
    }

    /// Fills in or corrects a set's numbers, any set at any time. A performed set is edited in the
    /// engine; an unperformed one (editing would invent it) is held in `pendingValues`. The two are
    /// indistinguishable from the screen.
    func updateSet(_ slot: LiftSlot, weightKg: Double?, reps: Int?, rpe: Double?, isWarmup: Bool) {
        if engine?.recordedSet(for: slot) != nil {
            engine?.updateSet(slot, weightKg: weightKg, reps: reps, rpe: rpe, isWarmup: isWarmup)
        } else if engine?.planItem(for: slot) != nil {
            let values = PendingSetValues(weightKg: weightKg, reps: reps, rpe: rpe)
            // Clearing the last field clears the entry, so the row returns to the plan's grey ghost.
            if values.isEmpty { pendingValues.removeValue(forKey: slot) }
            else { pendingValues[slot] = values }
        }
        persist()
    }

    /// What a slot is showing: what it recorded, or what was typed in advance.
    func enteredValues(for slot: LiftSlot) -> PendingSetValues {
        if let row = engine?.recordedSet(for: slot) {
            return PendingSetValues(weightKg: row.weightKg, reps: row.reps, rpe: row.rpe)
        }
        return pendingValues[slot] ?? PendingSetValues(weightKg: nil, reps: nil, rpe: nil)
    }

    func undo() {
        engine?.undo()
        persist()
    }

    func finish() {
        engine?.finish(now: Int(Date().timeIntervalSince1970))
        persist()
    }

    // MARK: - Finishing

    /// Sets never started. Finishing asks whether to complete them with grey numbers or discard them;
    /// a done set is never in question (`setsToSave`).
    var unfinishedSlots: [LiftSlot] { engine?.unperformedSlots ?? [] }

    /// One set as the finished session saves it. Timing is nil for a set completed at finish without
    /// being started, since inventing a moment would give it a rest and heart-rate window it never had.
    struct FinishedSet: Equatable {
        var slot: LiftSlot
        var weightKg: Double?
        var reps: Int?
        var rpe: Double?
        var isWarmup: Bool
        var startTs: Int?
        var endTs: Int?
        var restSec: Int?
    }

    /// The sets the session saves: every slot on the sheet. A done set saves what was typed, a blank
    /// number taking the grey value shown (a blank RPE takes the program line's max RPE; a previous
    /// set's rating is never copied). Never-started sets save grey numbers when `completingUnfinished`,
    /// else 0 kg x 0 reps, which figures leave out (`LiftMetrics.isPerformed`) and Edit sets still shows.
    /// Done sets keep order and timing; never-started follow in plan order with no timing.
    func setsToSave(completingUnfinished: Bool) -> [FinishedSet] {
        guard let engine else { return [] }
        // The plan's max RPE, which the session shows grey in the RPE field.
        func planned(_ slot: LiftSlot) -> Double? { engine.planItem(for: slot)?.targetRpe }
        var out = engine.sets.map { set -> FinishedSet in
            let shown = values(of: set.slot)
            return FinishedSet(slot: set.slot, weightKg: shown.weightKg, reps: shown.reps,
                               rpe: set.rpe ?? planned(set.slot), isWarmup: set.isWarmup,
                               startTs: set.startTs, endTs: set.endTs, restSec: set.restSec)
        }
        for slot in engine.allSlots where !engine.isCompleted(slot) {
            let typed = pendingValues[slot]
            let grey = carry(for: slot)
            out.append(FinishedSet(slot: slot,
                                   weightKg: completingUnfinished ? typed?.weightKg ?? grey.weightKg : 0,
                                   reps: completingUnfinished ? typed?.reps ?? grey.reps : 0,
                                   rpe: completingUnfinished ? typed?.rpe ?? planned(slot) : nil,
                                   isWarmup: pendingWarmups.contains(slot),
                                   startTs: nil, endTs: nil, restSec: nil))
        }
        return out
    }

    /// Whether any of `sets` was performed. When none was, `LiftSessionView.save` writes nothing and
    /// the finish sheet says so before Save.
    static func anyPerformed(_ sets: [FinishedSet]) -> Bool {
        sets.contains { LiftMetrics.isPerformed(reps: $0.reps) }
    }

    /// A program line whose set count this session changed.
    struct SetCountChange: Equatable {
        var itemId: String
        var exercise: String
        var from: Int
        var to: Int
    }

    /// Lines whose set count differs from the program's current one. A line with no count counts as
    /// one set; lines deleted from, or added to, the program meanwhile are skipped.
    static func setCountChanges(plan: [LiftPlanItem], program items: [LiftProgramItemRow]) -> [SetCountChange] {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.compactMap { line in
            guard let id = line.programItemId, let row = byId[id] else { return nil }
            let saved = max(1, row.targetSets ?? 1)
            guard saved != line.targetSets else { return nil }
            return SetCountChange(itemId: id, exercise: line.exercise, from: saved, to: line.targetSets)
        }
    }

    /// The program's lines with each one's HEAVIEST done set as its new weight and reps. A line holds
    /// one weight and rep count, so it takes the working weight (a lighter back-off must not pull it
    /// down), ties broken by more reps. Warm-ups, zeroed sets and sets completed at finish without
    /// being started move nothing. A number the set lacks is left as it was; a leftover rep-range top
    /// below the new count is dropped.
    static func applyingHeaviestSets(_ sets: [FinishedSet], plan: [LiftPlanItem],
                                     to items: [LiftProgramItemRow]) -> [LiftProgramItemRow] {
        var heaviest: [String: FinishedSet] = [:]
        for set in sets where set.startTs != nil && !set.isWarmup && LiftMetrics.isPerformed(reps: set.reps) {
            guard plan.indices.contains(set.slot.exerciseIndex),
                  let id = plan[set.slot.exerciseIndex].programItemId else { continue }
            if let best = heaviest[id], !isHeavier(set, than: best) { continue }
            heaviest[id] = set
        }
        return items.map { row in
            guard let top = heaviest[row.id] else { return row }
            var edited = row
            if let weight = top.weightKg { edited.targetWeightKg = weight }
            if let reps = top.reps {
                edited.targetRepsLow = reps
                if let high = edited.targetRepsHigh, high < reps { edited.targetRepsHigh = nil }
            }
            return edited
        }
    }

    /// More weight wins; at equal weight, more reps. A missing number ranks below any number.
    private static func isHeavier(_ a: FinishedSet, than b: FinishedSet) -> Bool {
        let (weightA, weightB) = (a.weightKg ?? -1, b.weightKg ?? -1)
        if weightA != weightB { return weightA > weightB }
        return (a.reps ?? -1) > (b.reps ?? -1)
    }

    /// The program's lines after this session, as `LiftSessionView.save` writes them. Every line takes
    /// its heaviest done set (`applyingHeaviestSets`); with `keepingChanges`, changed set counts move
    /// too and each exercise added during the session becomes a new line at the end (session set count,
    /// heaviest done set's weight and reps, else 0 x 0).
    static func programAfterSession(_ sets: [FinishedSet], plan: [LiftPlanItem],
                                    program items: [LiftProgramItemRow], keepingChanges: Bool,
                                    programId: String, deviceId: String) -> [LiftProgramItemRow] {
        var lines = items
        if keepingChanges {
            lines = applying(setCountChanges(plan: plan, program: items), to: lines)
            let next = (items.map(\.ord).max() ?? -1) + 1
            for (offset, line) in plan.filter(\.addedInSession).enumerated() {
                guard let id = line.programItemId, !lines.contains(where: { $0.id == id }) else { continue }
                lines.append(LiftProgramItemRow(
                    id: id, deviceId: deviceId, programId: programId, ord: next + offset,
                    exercise: line.exercise, targetSets: line.targetSets,
                    targetRepsLow: 0, targetRepsHigh: nil, targetRpe: nil, targetWeightKg: 0,
                    restSec: nil, note: nil))
            }
        }
        return applyingHeaviestSets(sets, plan: plan, to: lines)
    }

    /// The program's lines with `changes` applied; only `targetSets` moves.
    static func applying(_ changes: [SetCountChange], to items: [LiftProgramItemRow]) -> [LiftProgramItemRow] {
        let counts = Dictionary(changes.map { ($0.itemId, $0.to) }, uniquingKeysWith: { first, _ in first })
        return items.map { row in
            guard let sets = counts[row.id] else { return row }
            var edited = row
            edited.targetSets = sets
            return edited
        }
    }

    // MARK: - The rest's two moments
    //
    // Time alone changes a session at two moments per rest: the warning buzz `restWarningLeadSec`
    // before the end, and the end. Each gets a one-shot timer, replaced whenever the rest changes. A
    // per-second tick republished to every watching screen and got Zoop killed for background CPU;
    // on-screen clocks tick themselves, only while shown (`LiftRunningClock`).

    /// Re-arms the rest timers when the rest changed (new, undone, cut short, or none).
    private func scheduleRestTimers() {
        let endsAt: Int? = { if case .resting(_, let end) = engine?.stage { return end }; return nil }()
        guard endsAt != scheduledRestEnd else { return }
        scheduledRestEnd = endsAt
        restTimers.forEach { $0.cancel() }
        restTimers = []
        guard let endsAt else { return }
        let times = Self.restEventTimes(endsAt: endsAt, now: Self.unixNow)
        restTimers.append(after(times.warning) { $0.fireRestWarningIfDue() })
        if let end = times.end {
            restTimers.append(after(end) { $0.restDidEnd() })
        }
    }

    /// When a rest's warning and end fire, in unix seconds. The warning is `restWarningLeadSec` before
    /// the end, or one second from now when the rest is already inside that window, clear of the
    /// confirming buzz. The end fires only for a rest still to run.
    static func restEventTimes(endsAt: Int, now: Int) -> (warning: Int, end: Int?) {
        (warning: max(now + 1, endsAt - restWarningLeadSec), end: endsAt > now ? endsAt : nil)
    }

    /// Runs `action` on the main actor at unix second `unix`, unless cancelled first.
    private func after(_ unix: Int,
                       _ action: @escaping @MainActor (LiftSessionController) -> Void) -> Task<Void, Never> {
        let delay = Date(timeIntervalSince1970: TimeInterval(unix)).timeIntervalSinceNow
        return Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            action(self)
        }
    }

    private func fireRestWarningIfDue() {
        guard let engine, case .resting(_, let endsAt) = engine.stage else { return }
        guard warnedFor != endsAt else { return }
        guard endsAt - Self.unixNow <= LiftSessionController.restWarningLeadSec else { return }
        warnedFor = endsAt
        buzz(LiftSessionController.restWarningBuzzes)
    }

    /// The rest is over: "Resting after set 2" becomes "Ready for the next set" on screen and, via
    /// `changesSettled`, on the Lock Screen.
    private func restDidEnd() {
        objectWillChange.send()
    }

    // MARK: - Persistence

    private func persist() {
        guard let engine, !engine.isFinished else { return }
        LiftSessionPersistence.store(
            LiftSessionPersistence.snapshot(engine: engine,
                                            programId: programId,
                                            programName: programName,
                                            pendingValues: pendingValues,
                                            pendingWarmups: pendingWarmups))
    }
}
