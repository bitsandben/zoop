import Foundation
import SwiftUI
import StrandAnalytics
import WhoopStore

// MARK: - Training view model
//
// Everything the Training page reads or does that is not layout: loading, the week, the load model,
// the session list's filters and selection, and the edit actions. The screen only lays out what is
// published here.
//
// Environment objects (repository, profile, intelligence) are handed over once through `attach`,
// because a `@StateObject` is created before the environment is available.

@MainActor
final class TrainingViewModel: ObservableObject {

    /// First paint reads only this many trailing days, so a multi-thousand-workout import never sorts
    /// its whole history up front (#797). Opening the Archived list pages the rest in.
    static let firstPaintWindowDays = 400
    private static let fullWindowDays = 4000

    // MARK: Published state

    @Published private(set) var rows: [WorkoutRow]
    @Published private(set) var loaded: Bool
    @Published private(set) var week: TrainingWeek?
    @Published private(set) var load = TrainingLoadEngine.evaluate(days: [])
    @Published private(set) var cardio: TrainingLoadGauge.Reading?
    @Published private(set) var lift: LiftFitnessSnapshot = .empty
    /// One-line "sessions like this usually..." note shown briefly after a manual save or relabel (#439).
    @Published var postLogNote: String?

    @Published var scope: TrainingScope = .current {
        didSet { if scope == .archived { Task { await expandWindow() } } }
    }
    @Published var sportFilter: String?
    @Published var searchText = ""
    @Published var sourceFilter: WorkoutSource?

    /// The add/edit form: `.some(nil)` adds a workout, `.some(row)` edits one, `nil` is closed.
    @Published var editor: EditorTarget?
    @Published var selectionMode = false
    @Published private(set) var selected: Set<String> = []
    /// Pending merge whose rows are all bare detected bouts, so the user names the session first.
    @Published var mergeSportPrompt: MergeTarget?

    struct EditorTarget: Identifiable {
        let editing: WorkoutRow?
        /// "Duplicate as manual": the form pre-fills FROM a read-only row but the save is a pure add. The
        /// pre-fill carries the original's natural key while claiming source "manual", so it must never
        /// travel on as `replacing:` or the repository would retire the row it was copied from.
        var isCopy = false
        let id = UUID()
    }

    struct MergeTarget: Identifiable {
        let rows: [WorkoutRow]
        let id = UUID()
    }

    // MARK: Private state

    private var repo: Repository?
    private var profile: ProfileStore?
    private var intelligence: IntelligenceEngine?
    private let isPreview: Bool
    private var windowDays: Int?
    private var effortByDay: [String: Double] = [:]
    private(set) var programs: [LiftProgramRow] = []
    private var plan = TrainingPlan()

    init(previewRows: [WorkoutRow]? = nil) {
        rows = previewRows ?? []
        loaded = previewRows != nil
        isPreview = previewRows != nil
        windowDays = previewRows != nil ? nil : Self.firstPaintWindowDays
        if previewRows != nil { rebuildWeek() }
    }

    func attach(repo: Repository, profile: ProfileStore, intelligence: IntelligenceEngine) {
        self.repo = repo
        self.profile = profile
        self.intelligence = intelligence
    }

    // MARK: Loading

    /// Re-read every source. The week, the load model and the muscle figures all anchor on one `now`.
    func refresh() async {
        guard let repo, let profile, !isPreview else { return }
        // Not cancellation-guarded: refreshes can arrive in bursts (a backfill bumps `refreshSeq` per
        // slice), and a guard here would leave the page on its spinner until the bursts stop.
        rows = await repo.workoutRows(days: windowDays ?? Self.fullWindowDays)
        loaded = true

        let days = repo.days
        effortByDay = Dictionary(days.compactMap { d in d.strain.map { (d.day, $0) } }, uniquingKeysWith: max)
        let result = TrainingLoadEngine.evaluate(days: days.map {
            TrainingLoadEngine.DailyLoad(day: $0.day, load: $0.strain)
        })
        load = result
        cardio = TrainingLoadGauge.cardio(result)
        if let store = await repo.storeHandle() {
            programs = (try? await store.liftPrograms(deviceId: repo.deviceId)) ?? []
        }
        rebuildWeek()

        let snapshot = await LiftFitnessSnapshot.load(repo: repo, hrMax: profile.hrMax)
        guard !Task.isCancelled else { return }
        lift = snapshot
    }

    /// Re-read just the workouts after an edit, keeping the rest of the page as it is.
    private func reloadRows() async {
        guard let repo else { return }
        rows = await repo.workoutRows(days: windowDays ?? Self.fullWindowDays)
        rebuildWeek()
    }

    private func expandWindow() async {
        guard !isPreview, windowDays != nil else { return }
        windowDays = nil
        await reloadRows()
    }

    /// The Lift Log plan decides which days show a planned routine.
    func updatePlan(raw: String) {
        plan = TrainingPlan.decode(raw)
        rebuildWeek()
    }

    private func rebuildWeek() {
        week = TrainingWeek.make(rows: rows, effortByDay: effortByDay) { [programs, plan] date in
            let ids = plan.programIds(on: date, calendar: .current)
            return programs.filter { ids.contains($0.id) }
        }
    }

    // MARK: Session list

    var filter: WorkoutFilter { WorkoutFilter(sport: sportFilter, sourceClass: sourceFilter, search: searchText) }

    /// The rows the list shows: filtered, then cut to Current or Archived.
    var visibleRows: [WorkoutRow] { TrainingScope.rows(filter.apply(rows), scope: scope) }

    /// Displayed-sport names across all loaded rows, most frequent first, for the sport filter.
    var availableSports: [String] {
        var counts: [String: Int] = [:]
        for r in rows { counts[WorkoutSource.displaySport(r.sport), default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    func row(startTs: Int, sport: String) -> WorkoutRow? {
        rows.first { $0.startTs == startTs && $0.sport == sport }
    }

    // MARK: Selection and merge (#64)

    func key(_ row: WorkoutRow) -> String { "\(row.startTs)|\(row.sport)" }

    func isSelected(_ row: WorkoutRow) -> Bool { selected.contains(key(row)) }

    func toggleSelection(_ row: WorkoutRow) {
        let k = key(row)
        if selected.contains(k) { selected.remove(k) } else { selected.insert(k) }
    }

    func setSelectionMode(_ on: Bool) {
        selectionMode = on
        if !on { selected.removeAll() }
    }

    /// Merge straight away when the chosen rows carry a real sport; otherwise ask for a name first.
    func beginMerge(_ chosen: [WorkoutRow]) {
        guard WorkoutMerge.canMerge(chosen) else { return }
        if WorkoutMerge.resolvedSport(chosen) == nil {
            mergeSportPrompt = MergeTarget(rows: chosen)
        } else {
            performMerge(chosen, sport: nil)
        }
    }

    /// Imported rows never reach here: `canMerge` gates on manual and detected rows.
    func performMerge(_ chosen: [WorkoutRow], sport: String?) {
        guard let merged = WorkoutMerge.merge(chosen, sport: sport) else { return }
        setSelectionMode(false)
        mergeSportPrompt = nil
        Task {
            await repo?.mergeWorkouts(chosen, into: merged)
            await intelligence?.analyzeRecent()
            await reloadRows()
        }
    }

    func deleteSelected(_ chosen: [WorkoutRow]) {
        setSelectionMode(false)
        Task { await repo?.bulkDeleteWorkouts(chosen); await reloadRows() }
    }

    // MARK: Row actions

    func save(_ row: WorkoutRow, replacing: WorkoutRow?, isCopy: Bool) {
        Task {
            await repo?.saveManualWorkout(row, replacing: isCopy ? nil : replacing)
            // Rescore the new workout from the strap's HR now (#598), so its heart rate, effort and
            // calories appear immediately instead of at the next analyze tick.
            await intelligence?.analyzeRecent()
            await reloadRows()
            await showPostLogNote(forSport: row.sport)
        }
    }

    func relabel(_ row: WorkoutRow, to sport: String) {
        Task {
            await repo?.relabelDetected(row, sport: sport)
            await reloadRows()
            await showPostLogNote(forSport: sport)
        }
    }

    func dismiss(_ row: WorkoutRow) {
        Task { await repo?.dismissDetected(row); await reloadRows() }
    }

    func delete(_ row: WorkoutRow) {
        // Also drop the on-device GPS route stored under this session's natural key (#524).
        RouteStore.remove(startTs: row.startTs, sport: row.sport)
        Task { await repo?.deleteWorkout(row); await reloadRows() }
    }

    /// Shows the sport's recovery-cost sentence for a few seconds when the engine already has a pattern for it.
    private func showPostLogNote(forSport sport: String) async {
        guard let repo else { return }
        let sentence = TrainingActivityCost.sentence(forSport: sport, workouts: rows, days: repo.days)
        withAnimation(.easeOut(duration: 0.2)) { postLogNote = sentence }
        guard let sentence else { return }
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        if postLogNote == sentence { withAnimation(.easeOut(duration: 0.2)) { postLogNote = nil } }
    }
}
