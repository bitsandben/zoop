#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - My Day, dashboard, fitness age and the explainer inputs

extension TodayLoader {

    // MARK: My Day

    /// The sleeps that ended on the day (the night and any naps) and its workouts, oldest first. Night
    /// versus nap follows the Sleep screen's main-night pick, not a duration cut, so a night split by a
    /// wake-up never reads its shorter half as a nap here.
    func activities(key: String) async -> [TodayActivity] {
        func day(_ ts: Int) -> String { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(ts))) }
        let sleeps = repo.sleeps.filter { day($0.endTs) == key }
        let main = SleepView.mainNightGroup(sleeps)
        let mainStarts = Set(main.map(\.startTs))
        var items: [TodayActivity] = []
        if let first = main.first, let last = main.last {
            items.append(TodayActivity(kind: .sleep, title: String(localized: TodayCopy.activitySleep),
                                       start: first.effectiveStartTs, end: last.endTs))
        }
        for nap in sleeps where !mainStarts.contains(nap.startTs) {
            items.append(TodayActivity(kind: .nap, title: String(localized: TodayCopy.activityNap),
                                       start: nap.effectiveStartTs, end: nap.endTs, nap: nap))
        }
        for w in await repo.workoutRows(days: 3 + offset) where day(w.startTs) == key {
            items.append(TodayActivity(kind: .workout, title: WorkoutSource.displaySport(w.sport),
                                       start: w.startTs, end: w.endTs, workout: w))
        }
        // The unsaved detected workout sits with the day's activity, where a workout is looked for.
        if isToday, PuffinExperiment.autoDetectWorkoutsEnabled,
           let detected = await repo.homeAutoWorkoutCandidate(), day(detected.startSec) == key {
            items.append(TodayActivity(kind: .detected, title: String(localized: TodayCopy.activityDetected),
                                       start: detected.startSec, end: detected.endSec, detected: detected))
        }
        return items.sorted { $0.start < $1.start }
    }

    // MARK: Dashboard

    struct Dashboard {
        let readouts: [MetricReadout]
        let steps: [(day: String, value: Double)]
        let calories: [(day: String, value: Double)]
        let weight: [(day: String, value: Double)]
    }

    /// Steps, active calories and weight. Each day resolves with one precedence (strap, then Apple
    /// Health, then the motion estimate for steps; Apple Health first for calories, #616), so the value
    /// and the range it is judged against come from the same rule.
    func dashboard(key: String, row: DailyMetric?) async -> Dashboard {
        let apple = await repo.appleDailyRows(days: 120 + offset)
        let estimates = await repo.exploreSeries(key: "steps_est", source: "my-whoop", days: 120 + offset)
        let weighIns = await repo.series(key: "weight", source: "apple-health", days: 400 + offset)
        let appleByDay = Dictionary(grouping: apple, by: \.day)
        let estimateByDay = Dictionary(estimates.map { ($0.day, $0.value) }, uniquingKeysWith: { _, b in b })
        let rows = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        var dayKeys = Set(rows.keys).union(appleByDay.keys).union(estimateByDay.keys)
        if let row { dayKeys.insert(row.day) }

        func steps(_ d: String) -> Double? {
            let r = d == key ? row : rows[d]
            return r?.steps.map(Double.init) ?? appleByDay[d]?.compactMap(\.steps).max().map(Double.init)
                ?? estimateByDay[d]
        }
        func calories(_ d: String) -> Double? {
            appleByDay[d]?.compactMap(\.activeKcal).max() ?? (d == key ? row : rows[d])?.activeKcalEst
        }
        let sorted = dayKeys.filter { $0 <= key }.sorted()
        let stepSeries = sorted.compactMap { d in steps(d).map { (day: d, value: $0) } }
        let calorieSeries = sorted.compactMap { d in calories(d).map { (day: d, value: $0) } }
        func prior14(_ series: [(day: String, value: Double)]) -> [Double] {
            Array(series.filter { $0.day < key }.suffix(14).map(\.value))
        }

        var weights = weighIns.filter { $0.day <= key }
        for (d, rows) in appleByDay where d <= key {
            if let kg = rows.compactMap(\.weightKg).max(), !weights.contains(where: { $0.day == d }) {
                weights.append((day: d, value: kg))
            }
        }
        weights.sort { $0.day < $1.day }
        let latest = weights.last
        let earlier = latest.map { last in
            weights.dropLast().filter { TodayBodyReadouts.daysBetween($0.day, last.day) <= 90 }.map(\.value)
        } ?? []

        let readouts = [
            TodayBodyReadouts.dailyCount(id: .steps, value: steps(key), history: prior14(stepSeries),
                                         unit: .steps, population: 5_000...10_000),
            TodayBodyReadouts.dailyCount(id: .activeCalories, value: calories(key), history: prior14(calorieSeries),
                                         unit: .kilocalories, population: 300...700),
            TodayBodyReadouts.weight(latest: latest.map { ($0.day, $0.value) }, earlier: earlier,
                                     selectedDay: key),
        ]
        return Dashboard(readouts: readouts, steps: stepSeries, calories: calorieSeries, weight: weights)
    }

    // MARK: Fitness age

    struct FitnessResult {
        let readout: MetricReadout
        let history: [(day: String, value: Double)]
        let snapshot: FitnessAgeSnapshot
        /// The VO₂max line the Fitness age screen draws, 7-day averaged; read only for the VO₂max tile.
        let vo2Series: [(day: String, value: Double)]
    }

    func fitnessAge(key: String) async -> FitnessResult {
        let snapshot = await FitnessAgeSnapshot.load(repo: repo)
        let history = snapshot.history.filter { $0.day <= key }
        let readout = TodayBodyReadouts.fitnessAge(latest: history.last, age: env.profile.age, selectedDay: key)
        let vo2 = env.dashboardTiles.contains(.vo2max)
            ? FitnessAgeModel.rollingMean(await FitnessAgeModel.vo2Series(repo: repo, measured: snapshot.vo2IsMeasured, days: 60))
            : []
        return FitnessResult(readout: readout, history: history, snapshot: snapshot, vo2Series: vo2)
    }

    // MARK: Explainer inputs

    /// The 30 days ending on the selected day for every explainer, plus where the scores came from.
    func explanationInputs(key: String, scoreRow: DailyMetric?, stressTrend: [DaytimeStress.DailyPoint],
                           dashboard: Dashboard, fitness: [(day: String, value: Double)]) async -> TodayExplanations.Inputs {
        let from = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -29, to: logicalDay) ?? logicalDay)
        let window = repo.days.filter { $0.day >= from && $0.day <= key }
        func points(_ pairs: [(day: String, value: Double)]) -> [MetricExplanation.TrendPoint] {
            pairs.filter { $0.day >= from && $0.day <= key }.compactMap { p in
                TodayLogic.dayKeyParser.date(from: p.day).map { MetricExplanation.TrendPoint(date: $0, value: p.value) }
            }
        }
        let scale = env.whoopScale ? TodayRings.strainScaleFactor : 1
        let sleep = window.compactMap { d in
            TodayRings.sleepScore(wakeDay: d.day, importedPct: repo.importedSleep[d.day]?.performancePct, row: d)
                .map { (day: d.day, value: $0) }
        }
        var inputs = TodayExplanations.Inputs()
        inputs.trends = [
            .recovery: points(window.compactMap { d in d.recovery.map { (day: d.day, value: $0) } }),
            .sleepScore: points(sleep),
            .strain: points(window.compactMap { d in d.strain.map { (day: d.day, value: $0 * scale) } }),
            .stress: points(stressTrend.map { (day: $0.day, value: $0.level) }),
            .stressDaily: points(stressTrend.map { (day: $0.day, value: $0.level) }),
            .steps: points(dashboard.steps),
            .activeCalories: points(dashboard.calories),
            .weight: points(dashboard.weight),
            .fitnessAge: points(fitness),
        ]
        inputs.scoreSource = await scoreSource(day: scoreRow?.day ?? key)
        if let row = scoreRow, let baselines = repo.chargeBaselines {
            inputs.recoveryDrivers = ChargeBreakdownWiring.breakdown(
                baselines: baselines, row: row, charge: RecoveryCalibrationStore.lastScoring)?.drivers ?? []
        }
        return inputs
    }

    /// The provider whose data won the Recovery for that day, named the way the data tables name it.
    private func scoreSource(day: String) async -> String? {
        let resolution = await repo.resolvedSeries(key: "recovery", source: Repository.whoopSource, from: day, to: day)
        guard let winner = resolution.points.last(where: { $0.day == day }) else { return nil }
        let provider = await repo.scoreInputProvider(resolvedSource: winner.source, day: winner.day, metricKey: "recovery")
        return provider.flatMap { TodayLogic.scoreSourceLabel(providers: [$0]) }
    }
}
#endif
