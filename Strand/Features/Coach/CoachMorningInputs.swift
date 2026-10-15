#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopStore

/// Collects the morning's facts for `CoachMorningRules` from the same resolvers the screens use, so
/// the coach never quotes a number the app shows differently: the sleep planner's bedtime, the Charge
/// strain band, the Body trends and stress timing, the training-load gauge, the sleep insights, the
/// Lift Log plan and the fasting log.
@MainActor
enum CoachMorningInputs {

    /// HRV baseline window, the one `CoachSuggestions` uses for its chips.
    private static let hrvWindow = 30
    /// The first morning the coach saw a weekly plan; earlier days are not counted as missed, because
    /// the plan carries no creation date of its own.
    static let planSeenKey = "zoop.coach.planSeenSince"

    static func gather(repo: Repository, illness: Bool, now: Date) async -> CoachMorningRules.Input {
        var input = CoachMorningRules.Input()
        let days = repo.days
        let today = repo.today
        let todayKey = Repository.localDayKey(now)
        input.recovery = today?.recovery
        input.hrv = today?.avgHrv
        input.hrvBaseline = hrvBaseline(days, excluding: today?.day)
        input.hrvTrend = trend(BodyInsights.direction(BodyInsights.hrv(days), asOf: todayKey))
        input.rhrTrend = trend(BodyInsights.direction(BodyInsights.restingHR(days), asOf: todayKey))
        input.sleepMin = today?.totalSleepMin
        let ledger = SleepModel.debtLedger(days: days, napSleepMinByDay: [:])
        input.sleepDebtMin = ledger.isDebt ? ledger.magnitudeMin : 0
        input.strainTarget = CoupledView.optimalStrainRange(recovery: today?.recovery)
        input.illness = illness

        let load = TrainingLoadGauge.cardio(TrainingLoadEngine.evaluate(days: days.map {
            TrainingLoadEngine.DailyLoad(day: $0.day, load: $0.strain)
        }))
        if load.state != .calibrating {
            input.loadState = load.state
            if let a = load.acute, let c = load.chronic, c > 0 { input.loadRatio = a / c }
        }

        // The planner's own resolver: wake time (alarm / reminder / habit) minus tonight's time in bed.
        let patterns = PatternsModel()
        await patterns.loadQuick(repo: repo)
        input.bedtimeMinute = patterns.tonight?.bedtime.map { $0 / 60 }
        addSleepTiming(to: &input, repo: repo, todayKey: todayKey)

        let stored = await repo.series(key: "stress", source: "my-whoop")
        input.stressLevel = DaytimeStress.daily(days: days, stored: stored)?.level
        if let timing = await BodyLoader().stressTiming(repo: repo) {
            input.stressPeakHour = timing.peakHour
            input.stressPeakLevel = timing.peakMean
        }

        let workouts = await repo.workoutRows(days: CoachAdherence.windowDays + 1)
        if let store = await repo.storeHandle() {
            await addRoutines(to: &input, store: store, deviceId: repo.deviceId, workouts: workouts, now: now)
            input.fasting = await fasting(store: store, now: now)
        }
        let suppressed = CoachSuggestionStore.shared.suppressed()
        input.suppressedReasons = suppressed.reasons
        input.suppressedKinds = suppressed.kinds
        return input
    }

    /// The illness engine raised a signal, or the user logged feeling unwell: the coach rests the day.
    static func isUnwell(_ result: IllnessSignalEngine.Result?) -> Bool {
        guard let level = result?.level else { return false }
        return level == .raised || level == .alreadyUnwell
    }

    /// The user's Effort scale, for printing a strain band the way the Today ring prints it.
    static var whoopScale: Bool {
        let raw = UserDefaults.standard.string(forKey: UnitPrefs.effortScaleKey) ?? EffortScale.hundred.rawValue
        return UnitPrefs.resolveEffortScale(raw) == .whoop
    }

    private static func hrvBaseline(_ days: [DailyMetric], excluding day: String?) -> Double? {
        let values = days.suffix(hrvWindow).filter { $0.day != day }.compactMap(\.avgHrv)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func trend(_ d: BodyInsights.Direction?) -> CoachMorningRules.Trend? {
        guard let d, d.streakDays > 0 else { return nil }
        return .init(below: d.trend == .belowStreak, streakDays: d.streakDays, deltaPercent: d.deltaPercent)
    }

    /// Last night's start, the usual bedtime (median of the last two weeks) and the bedtime window before
    /// the best recoveries (Sleep insights).
    private static func addSleepTiming(to input: inout CoachMorningRules.Input, repo: Repository, todayKey: String) {
        let nights = SleepInsightsSection.nights(sleeps: repo.sleeps, days: repo.days, withLatency: false)
        if let last = nights.last(where: { $0.wakeDay == todayKey }) {
            input.lastBedtimeMinute = Int(last.bedtimeClockMin.rounded())
        }
        let recent = nights.suffix(14).map(\.bedtimeSignedMin).sorted()
        if recent.count >= 3 {
            input.usualBedtimeMinute = Int(SleepInsights.clock(fromSigned: recent[recent.count / 2]).rounded())
        }
        if let window = SleepInsights.bedtime(nights), !window.isFlat {
            input.bestBedtimeMinute = Int(SleepInsights.clock(fromSigned: window.best.center).rounded())
        }
    }

    /// Planned = in today's Lift Log plan. Available = everything else, least recently touched first,
    /// so a green-day proposal rotates through the programs instead of always naming the newest.
    /// Adherence counts the weekly plan's days of the last two weeks against any recorded workout.
    private static func addRoutines(to input: inout CoachMorningRules.Input, store: WhoopStore, deviceId: String,
                                    workouts: [WorkoutRow], now: Date) async {
        let programs = (try? await store.liftPrograms(deviceId: deviceId)) ?? []
        let plan = TrainingPlan.decode(UserDefaults.standard.string(forKey: TrainingPlan.storageKey) ?? "")
        let plannedIds = Set(plan.programIds(on: now))
        input.plannedRoutines = programs.filter { plannedIds.contains($0.id) }
            .map { .init(id: $0.id, name: $0.name) }
        input.availableRoutines = programs.filter { !plannedIds.contains($0.id) }
            .sorted { $0.updatedAt < $1.updatedAt }
            .map { .init(id: $0.id, name: $0.name) }
        let from = Int(now.timeIntervalSince1970) - (CoachAdherence.windowDays + 1) * 86_400
        let sessions = (try? await store.liftSessions(deviceId: deviceId, fromTs: from,
                                                      toTs: Int(now.timeIntervalSince1970))) ?? []
        input.adherence = adherence(plan: plan, programs: programs, workouts: workouts, sessions: sessions, now: now)
    }

    private static func adherence(plan: TrainingPlan, programs: [LiftProgramRow], workouts: [WorkoutRow],
                                  sessions: [LiftSessionRow], now: Date) -> CoachAdherence.Result? {
        guard !plan.weekdays.isEmpty else { return nil }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: planSeenKey) == nil { defaults.set(now.timeIntervalSince1970, forKey: planSeenKey) }
        let seen = Date(timeIntervalSince1970: defaults.double(forKey: planSeenKey))
        let cal = Calendar.current
        let starts = workouts.map(\.startTs) + sessions.map(\.startTs)
        let trainedDays = Set(starts.map { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0))) })
        // A day counts once the plan was seen, or once a planned program had already been run.
        let firstPlannedRun = sessions.filter { $0.programId.map { plan.weekdays[$0] != nil } ?? false }
            .map(\.startTs).min().map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let since = min(seen, firstPlannedRun ?? seen)
        let created = Dictionary(programs.map { ($0.id, Date(timeIntervalSince1970: TimeInterval($0.createdAt))) },
                                 uniquingKeysWith: min)
        var days: [CoachAdherence.Day] = []
        for back in 1...CoachAdherence.windowDays {
            guard let date = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: now)),
                  date >= cal.startOfDay(for: since) else { continue }
            let weekday = cal.component(.weekday, from: date)
            let planned = plan.weekdays.filter { $0.value.contains(weekday) }.keys
                .filter { id in created[id].map { $0 <= date } ?? false }
                .sorted()
            let key = Repository.localDayKey(date)
            days.append(.init(day: key, plannedProgramIds: planned, trained: trainedDays.contains(key)))
        }
        return CoachAdherence.evaluate(days)
    }

    /// Only while a fast is running: elapsed time and its goal.
    private static func fasting(store: WhoopStore, now: Date) async -> CoachMorningRules.Fasting? {
        let rows = await FastingLog.load(store: store, now: now)
        guard let active = rows.map(FastingInterval.init).first(where: \.isActive) else { return nil }
        let goal = active.goal > 0 ? active.goal / 3600 : FastingPreferences.plan.fastingHours
        return .init(elapsedHours: now.timeIntervalSince(active.start) / 3600, targetHours: goal)
    }
}
#endif
