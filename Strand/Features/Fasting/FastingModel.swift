#if os(iOS)
import Foundation
import Observation
import StrandAnalytics
import StrandDesign
import WhoopStore

/// A start/end pair being edited in the sheet: a backdated start, a stop that happened earlier, or an
/// old fast being corrected. `end == nil` keeps the fast running.
struct FastingDraft: Identifiable, Equatable {
    /// nil for a fast that does not exist yet ("Started earlier").
    let rowID: String?
    var start: Date
    var end: Date?
    /// Only the running fast (or a new one) may stay open.
    let canRun: Bool

    var id: String { rowID ?? "new" }
}

/// The Fasting screen's state and intents. Reads the log from the store and the nightly values from the
/// Repository; every derived number comes from `FastingEngine` and is formatted in FastingPresentation.
@Observable @MainActor
final class FastingModel {
    private(set) var rows: [FastingSessionRow] = []
    private(set) var plan: FastingPlan = FastingPreferences.plan
    private(set) var planSummary: FastingPlanSummary?
    private(set) var week: FastingWeek?
    private(set) var streak: LocalizedStringResource?
    private(set) var consistency: LocalizedStringResource?
    private(set) var history: [FastingHistoryItem] = []
    private(set) var patterns: FastingPatterns?
    private(set) var reminderEnabled = FastingPreferences.reminderEnabled
    private(set) var reminderDenied = false
    private(set) var saveError: LocalizedStringResource?
    private(set) var loaded = false

    /// The one clock for this screen; injectable for tests.
    var now: () -> Date = Date.init
    private var repo: Repository?
    private let calendar = Calendar.current

    /// Rows shown in history: the newest finished fasts.
    static let historyLimit = 12

    var activeRow: FastingSessionRow? { rows.first { $0.endTs == nil } }
    private var intervals: [FastingInterval] { rows.map(FastingInterval.init) }
    private var lastEnd: Date? {
        intervals.compactMap(\.end).max()
    }

    // MARK: Loading

    func load(repo: Repository) async {
        self.repo = repo
        guard let store = await repo.storeHandle() else { return }
        #if DEBUG
        await FastingDemoSeed.seedIfRequested(store: store, now: now())
        #endif
        rows = await FastingLog.load(store: store, now: now())
        rebuild()
        loaded = true
    }

    /// Everything derived from `rows`, recomputed after each load or write.
    private func rebuild() {
        let now = now()
        plan = FastingPreferences.plan
        let all = intervals
        let active = all.first(where: \.isActive)
        planSummary = .make(plan: plan, active: active, lastEnd: lastEnd, now: now)
        week = .make(FastingEngine.week(all, now: now, calendar: calendar), plan: plan)
        streak = FastingStrings.streakValue(FastingEngine.streak(all, now: now, calendar: calendar))
        let c = FastingEngine.consistency(all, now: now, days: 30, calendar: calendar)
        consistency = FastingStrings.consistencyValue(met: c.metDays, of: c.consideredDays)
        history = rows.compactMap(FastingHistoryItem.make).prefix(Self.historyLimit).map { $0 }
        patterns = makePatterns(all, now: now)
    }

    private func makePatterns(_ all: [FastingInterval], now: Date) -> FastingPatterns? {
        guard let repo, !all.isEmpty else { return nil }
        let split = FastingEngine.nightSplit(all, now: now, calendar: calendar)
        var rhr: [String: Double] = [:], hrv: [String: Double] = [:], recovery: [String: Double] = [:]
        for d in repo.days {
            if let v = d.restingHr { rhr[d.day] = Double(v) }
            if let v = d.avgHrv { hrv[d.day] = v }
            if let v = d.recovery { recovery[d.day] = v }
        }
        return .make(split: split, outcomes: [
            .init(key: "resting_hr", label: FastingStrings.outcomeRestingHR, unit: .beatsPerMinute, byDay: rhr),
            .init(key: "hrv", label: FastingStrings.outcomeHRV, unit: .milliseconds, byDay: hrv),
            .init(key: "recovery", label: FastingStrings.outcomeRecovery, unit: .percent, byDay: recovery),
        ])
    }

    /// The timer card at `date` (the view's TimelineView drives the tick).
    func timer(at date: Date) -> FastingTimerState {
        .make(active: activeRow.map(FastingInterval.init), lastEnd: lastEnd, now: date)
    }

    // MARK: Intents

    func startFast() async {
        let t = now()
        await write { store in _ = try await FastingLog.start(store: store, at: t, now: t, source: .app) }
    }

    func stopFast() async {
        let t = now()
        await write { store in _ = try await FastingLog.stop(store: store, at: t) }
    }

    func draftForStartEarlier() -> FastingDraft {
        FastingDraft(rowID: nil, start: now().addingTimeInterval(-3600), end: nil, canRun: true)
    }

    func draft(for row: FastingSessionRow) -> FastingDraft {
        let i = FastingInterval(row)
        return FastingDraft(rowID: row.id, start: i.start, end: i.end, canRun: row.endTs == nil)
    }

    /// The validation message for a draft, or nil when it can be saved.
    func problem(with draft: FastingDraft) -> LocalizedStringResource? {
        let others = intervals.filter { $0.id != draft.rowID }
        return FastingStrings.validation(FastingEngine.validate(start: draft.start, end: draft.end,
                                                                now: now(), others: others))
    }

    func save(_ draft: FastingDraft) async {
        guard problem(with: draft) == nil else { return }
        let existing = rows.first { $0.id == draft.rowID }
        let row = FastingSessionRow(
            id: existing?.id ?? UUID().uuidString,
            startTs: Int(draft.start.timeIntervalSince1970),
            endTs: draft.end.map { Int($0.timeIntervalSince1970) },
            goalSec: existing?.goalSec ?? Int(plan.goal),
            planId: existing?.planId ?? plan.id,
            note: existing?.note,
            source: existing?.source ?? FastingLog.Source.app.rawValue)
        await write { store in try await FastingLog.save(store: store, row) }
    }

    func delete(rowID: String) async {
        guard let row = rows.first(where: { $0.id == rowID }) else { return }
        await write { store in try await FastingLog.delete(store: store, row) }
    }

    func choosePlan(_ plan: FastingPlan) {
        FastingPreferences.setPlan(plan)
        rebuild()
    }

    func setReminder(_ on: Bool) async {
        let outcome = await FastingReminder.setEnabled(on, active: activeRow)
        reminderEnabled = FastingPreferences.reminderEnabled
        reminderDenied = on && outcome == .denied
    }

    /// Runs one write, reloads, and surfaces a failure instead of swallowing it.
    private func write(_ body: (WhoopStore) async throws -> Void) async {
        guard let store = await repo?.storeHandle() else { saveError = FastingStrings.saveFailed; return }
        do {
            try await body(store)
            saveError = nil
        } catch {
            saveError = FastingStrings.saveFailed
        }
        rows = await FastingLog.load(store: store, now: now())
        rebuild()
    }
}
#endif
