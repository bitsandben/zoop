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

/// An eating window being edited: `opens` is the earlier fast's end (first meal), `closes` the later
/// fast's start (last meal).
struct FastingWindowDraft: Identifiable, Equatable {
    let previous: FastingSessionRow
    let next: FastingSessionRow
    var opens: Date
    var closes: Date

    var id: String { previous.id + ">" + next.id }
}

/// The Fasting screen's state and intents. Reads the log from the store and the nightly values from the
/// Repository; every derived number comes from `FastingEngine` / `FastingCycle` and is formatted in the
/// presentation builders.
@Observable @MainActor
final class FastingModel {
    private(set) var rows: [FastingSessionRow] = []
    private(set) var schedule: FastingSchedule = FastingPreferences.schedule
    private(set) var scheduleSummary: FastingScheduleSummary?
    private(set) var week: FastingTimelineWeek?
    private(set) var stats: FastingStatsModel?
    private(set) var history: [FastingHistoryItem] = []
    private(set) var patterns: FastingPatterns?
    private(set) var deniedReminder: FastingPreferences.Reminder?
    private(set) var saveError: LocalizedStringResource?
    private(set) var loaded = false
    /// Bumped on every rebuild so settings read from UserDefaults re-render their toggles.
    private(set) var settingsRevision = 0

    /// The one clock for this screen; injectable for tests.
    var now: () -> Date = Date.init
    private var repo: Repository?
    private let calendar = Calendar.current

    /// Rows shown in history: the newest fasts and eating windows.
    static let historyLimit = 16

    var plan: FastingPlan { schedule.plan }
    var activeRow: FastingSessionRow? { rows.first { $0.endTs == nil } }
    private var intervals: [FastingInterval] { rows.map(FastingInterval.init) }
    private var lastEnd: Date? { intervals.compactMap(\.end).max() }

    // MARK: Loading

    func load(repo: Repository) async {
        self.repo = repo
        guard let store = await repo.storeHandle() else { return }
        #if DEBUG
        await FastingDemoSeed.seedIfRequested(store: store, now: now())
        #endif
        rows = await FastingLog.reconcile(store: store, now: now())
        rebuild()
        loaded = true
    }

    /// Everything derived from `rows`, recomputed after each load or write.
    private func rebuild() {
        settingsRevision &+= 1
        let now = now()
        schedule = FastingPreferences.schedule
        let all = intervals
        scheduleSummary = .make(schedule)
        var open: EatingWindow?
        if case .eating(let w) = FastingLog.state(rows, now: now) { open = w }
        week = .make(FastingCycle.timeline(all, open: open, now: now, calendar: calendar),
                     week: FastingEngine.week(all, now: now, calendar: calendar))
        stats = .make(FastingCycle.stats(all, now: now, calendar: calendar),
                      streak: FastingEngine.streak(all, now: now, calendar: calendar),
                      consistency: FastingEngine.consistency(all, now: now, days: 30, calendar: calendar))
        history = FastingHistoryItem.make(rows: rows, limit: Self.historyLimit)
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

    /// The hero at `date` (the view's TimelineView drives the tick).
    func timer(at date: Date) -> FastingTimerState {
        .make(FastingLog.state(rows, now: date), schedule: schedule, lastEnd: lastEnd, now: date)
    }

    // MARK: Fasts

    func startFast() async {
        let t = now()
        await write { store in _ = try await FastingLog.start(store: store, at: t, now: t, source: .app) }
    }

    /// Ends the fast; the eating window opens at the same instant.
    func stopFast() async {
        let t = now()
        await write { store in _ = try await FastingLog.stop(store: store, at: t) }
    }

    /// A backdated start an hour ago, but never before the last meal of the open window.
    func draftForStartEarlier() -> FastingDraft {
        var start = now().addingTimeInterval(-3600)
        if let lastEnd, lastEnd > start { start = min(now(), lastEnd.addingTimeInterval(60)) }
        return FastingDraft(rowID: nil, start: start, end: nil, canRun: true)
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

    // MARK: Eating windows

    func windowDraft(previous: FastingSessionRow, next: FastingSessionRow) -> FastingWindowDraft? {
        guard let end = previous.endTs else { return nil }
        return FastingWindowDraft(previous: previous, next: next,
                                  opens: Date(timeIntervalSince1970: TimeInterval(end)),
                                  closes: Date(timeIntervalSince1970: TimeInterval(next.startTs)))
    }

    func problem(with draft: FastingWindowDraft) -> LocalizedStringResource? {
        FastingStrings.validation(FastingCycle.validateWindow(
            opens: draft.opens, closes: draft.closes, previous: FastingInterval(draft.previous),
            next: FastingInterval(draft.next), now: now(), others: intervals))
    }

    func save(_ draft: FastingWindowDraft) async {
        guard problem(with: draft) == nil else { return }
        await write { store in
            try await FastingLog.saveWindow(store: store, previous: draft.previous, next: draft.next,
                                            opens: draft.opens, closes: draft.closes)
        }
    }

    // MARK: Schedule and reminders

    func choosePlan(_ plan: FastingPlan) {
        FastingPreferences.setPlan(plan)
        scheduleChanged()
    }

    func setFixedStart(_ on: Bool) {
        FastingPreferences.usesFixedStart = on
        scheduleChanged()
    }

    func setStartMinute(_ minute: Int) {
        FastingPreferences.startMinute = minute
        scheduleChanged()
    }

    func setAutoStart(_ on: Bool) {
        FastingPreferences.autoStart = on
        // Arming it must not backfill the window that is already due; it applies from the next one.
        if on, case .due(let since) = FastingLog.state(rows, now: now()) { FastingPreferences.lastAutoStart = since }
        scheduleChanged()
    }

    func setShowOnToday(_ on: Bool) {
        FastingPreferences.showOnToday = on
        rebuild()
        NotificationCenter.default.post(name: FastingLog.didChange, object: nil)
    }

    func isOn(_ reminder: FastingPreferences.Reminder) -> Bool { _ = settingsRevision; return FastingPreferences.isOn(reminder) }
    var autoStart: Bool { _ = settingsRevision; return FastingPreferences.autoStart }
    var showOnToday: Bool { _ = settingsRevision; return FastingPreferences.showOnToday }
    var startMinute: Int { _ = settingsRevision; return FastingPreferences.startMinute }

    func setReminder(_ reminder: FastingPreferences.Reminder, _ on: Bool) async {
        let t = now()
        let outcome = await FastingReminder.setEnabled(reminder, on, state: FastingLog.state(rows, now: t), now: t)
        deniedReminder = on && outcome == .denied ? reminder : nil
        rebuild()
    }

    /// A schedule edit is the user setting a plan, so the Today card turns on with it.
    private func scheduleChanged() {
        FastingPreferences.showOnToday = true
        rebuild()
        FastingReminder.sync(state: FastingLog.state(rows, now: now()), now: now())
        NotificationCenter.default.post(name: FastingLog.didChange, object: nil)
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
