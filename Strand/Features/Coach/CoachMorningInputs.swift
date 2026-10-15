#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopStore

/// Collects the morning's facts for `CoachMorningRules` from the same resolvers the screens use, so
/// the coach never quotes a number the app shows differently: the sleep planner's bedtime, the Charge
/// strain band, the Lift Log plan, the daily stress level and the fasting log.
@MainActor
enum CoachMorningInputs {

    /// HRV baseline window, the one `CoachSuggestions` uses for its chips.
    private static let hrvWindow = 30
    /// A fast in this window counts as "this person fasts", the Today fasting card's rule.
    private static let fastingRecent: TimeInterval = FastingTodayState.recentWindow

    static func gather(repo: Repository, now: Date) async -> CoachMorningRules.Input {
        var input = CoachMorningRules.Input()
        let days = repo.days
        let today = repo.today
        input.recovery = today?.recovery
        input.hrv = today?.avgHrv
        input.hrvBaseline = hrvBaseline(days, excluding: today?.day)
        input.sleepMin = today?.totalSleepMin
        let ledger = SleepModel.debtLedger(days: days, napSleepMinByDay: [:])
        input.sleepDebtMin = ledger.isDebt ? ledger.magnitudeMin : 0
        input.strainTarget = CoupledView.optimalStrainRange(recovery: today?.recovery)

        // The planner's own resolver: wake time (alarm / reminder / habit) minus tonight's time in bed.
        let patterns = PatternsModel()
        await patterns.loadQuick(repo: repo)
        input.bedtimeMinute = patterns.tonight?.bedtime.map { $0 / 60 }

        let stored = await repo.series(key: "stress", source: "my-whoop")
        input.stressLevel = DaytimeStress.daily(days: days, stored: stored)?.level

        if let store = await repo.storeHandle() {
            await addRoutines(to: &input, store: store, deviceId: repo.deviceId, now: now)
            input.fasting = await fasting(store: store, now: now)
        }
        let suppressed = CoachSuggestionStore.shared.suppressed()
        input.suppressedReasons = suppressed.reasons
        input.suppressedKinds = suppressed.kinds
        return input
    }

    private static func hrvBaseline(_ days: [DailyMetric], excluding day: String?) -> Double? {
        let values = days.suffix(hrvWindow).filter { $0.day != day }.compactMap(\.avgHrv)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Planned = in today's Lift Log plan. Available = everything else, least recently touched first,
    /// so a green-day proposal rotates through the programs instead of always naming the newest.
    private static func addRoutines(to input: inout CoachMorningRules.Input, store: WhoopStore,
                                    deviceId: String, now: Date) async {
        let programs = (try? await store.liftPrograms(deviceId: deviceId)) ?? []
        let plan = TrainingPlan.decode(UserDefaults.standard.string(forKey: TrainingPlan.storageKey) ?? "")
        let plannedIds = Set(plan.programIds(on: now))
        input.plannedRoutines = programs.filter { plannedIds.contains($0.id) }
            .map { .init(id: $0.id, name: $0.name) }
        input.availableRoutines = programs.filter { !plannedIds.contains($0.id) }
            .sorted { $0.updatedAt < $1.updatedAt }
            .map { .init(id: $0.id, name: $0.name) }
    }

    /// Nil for people who have not fasted in the last week. The next start is the last fast's end plus
    /// the plan's eating window, the Today card's "next fast" time, when it still lies ahead today.
    private static func fasting(store: WhoopStore, now: Date) async -> CoachMorningRules.Fasting? {
        let rows = await FastingLog.load(store: store, now: now)
        let intervals = rows.map(FastingInterval.init)
        guard intervals.contains(where: { $0.start >= now.addingTimeInterval(-fastingRecent) }) else { return nil }
        let plan = FastingPreferences.plan
        let active = intervals.contains(where: \.isActive)
        var nextMinute: Int?
        if !active, let lastEnd = intervals.compactMap(\.end).max() {
            let next = lastEnd.addingTimeInterval(plan.eatingHours * 3600)
            if next > now, Calendar.current.isDate(next, inSameDayAs: now) {
                let c = Calendar.current.dateComponents([.hour, .minute], from: next)
                nextMinute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        }
        return .init(active: active, nextStartMinute: nextMinute, planId: plan.id, fastingHours: plan.fastingHours)
    }
}
#endif
