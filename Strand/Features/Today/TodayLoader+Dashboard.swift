#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - My Dashboard tiles
//
// Only the tiles the user picked are read. Each one comes from the resolver of the screen that owns the
// number (Body for the vitals, Sleep for the debt, Fitness age for VO₂max, Fasting for the streak), so a
// tile and the screen behind it show the same value.

extension TodayLoader {

    struct DashboardTiles {
        var readouts: [(kind: TodayTileKind, readout: MetricReadout)] = []
        /// Explanations the owning screens built, keyed by readout id.
        var owned: [MetricID: MetricExplanation] = [:]
    }

    func dashboardTiles(key: String, counts: Dashboard, fitness: FitnessResult,
                        live: Live) async -> DashboardTiles {
        let kinds = env.dashboardTiles
        var out = DashboardTiles()
        let vitals = kinds.contains(where: Self.vitalKinds.keys.contains) ? await vitals(key: key) : []
        for kind in kinds {
            switch kind {
            case .hrv, .restingHR, .respiratory, .spo2, .skinTemp:
                guard let id = Self.vitalKinds[kind], let vital = vitals.first(where: { $0.id == id }) else { continue }
                out.readouts.append((kind, vital.readout))
                out.owned[id] = vital.metric.explanation
            case .steps, .calories, .weight:
                let id: MetricID = kind == .steps ? .steps : (kind == .calories ? .activeCalories : .weight)
                if let readout = counts.readouts.first(where: { $0.id == id }) { out.readouts.append((kind, readout)) }
            case .stress:
                out.readouts.append((kind, TodayBodyReadouts.stressDaily(live.daily, dayKey: key)))
            case .sleepDebt:
                let debt = await sleepDebt(key: key)
                out.readouts.append((kind, debt.readout))
                out.owned[debt.readout.id] = debt.explanation
            case .fitnessAge:
                out.readouts.append((kind, fitness.readout))
            case .vo2max:
                if let item = vo2max(fitness: fitness, key: key) {
                    out.readouts.append((kind, item.readout))
                    out.owned[item.readout.id] = item.explanation
                } else {
                    out.readouts.append((kind, TodayBodyReadouts.unavailable(kind, id: .vo2max, unit: .vo2max,
                                                                             meaning: TodayCopy.vo2NoData)))
                }
            case .energy:
                out.readouts.append((kind, live.energy ?? TodayBodyReadouts.energy(nil)))
            case .fasting:
                out.readouts.append((kind, await fastingStreak()))
            }
        }
        return out
    }

    /// The trend under each tile is its explainer's, so the sparkline and the sheet draw the same days.
    static func tiles(_ built: DashboardTiles, inputs: TodayExplanations.Inputs) -> [TodayDashboardTile] {
        built.readouts.map { item in
            TodayDashboardTile(kind: item.kind, readout: item.readout,
                               trend: TodayExplanations.explanation(for: item.readout.id, inputs: inputs).trend)
        }
    }

    // MARK: Sources

    private static let vitalKinds: [TodayTileKind: MetricID] = [
        .hrv: .hrv, .restingHR: .restingHeartRate, .respiratory: .respiratoryRate,
        .spo2: .spo2, .skinTemp: .skinTemperature,
    ]

    /// The Body screen's five vitals as they stood on the selected day.
    private func vitals(key: String) async -> [BodyVital] {
        // #1118: nights whose HRV the WHOOP 4.0 over-counted stay out, as on the Body screen.
        let overCount = await repo.exploreSeries(key: "hrv_rr_overcount", source: "my-whoop", days: 45 + offset)
        let flagged = Set(overCount.filter { $0.value >= 0.5 }.map(\.day))
        let rows = repo.vitalMetricRows.filter { $0.metric.day <= key }
        return BodyVitals.build(rows: rows, overCountDays: flagged, today: key)
    }

    /// The Sleep screen's debt ledger (naps credited), over the nights up to the selected day.
    private func sleepDebt(key: String) async -> SleepMetric {
        let sessions = await repo.allSleepSessions()
        let habitual = await repo.habitualMidsleepSec()
        let nav = SleepModel.navDays(navSessions: sessions.isEmpty ? repo.sleeps : sessions)
        let naps = SleepModel.napSleepMinutesByDay(navDays: nav, habitualMidsleepSec: habitual)
        let days = repo.days.filter { $0.day <= key }
        return SleepReadouts.debt(ledger: SleepModel.debtLedger(days: days, napSleepMinByDay: naps),
                                  keyed: SleepModel.sleepDebtHistory(days: days, importedSleep: repo.importedSleep,
                                                                     napSleepMinByDay: naps))
    }

    /// The Fitness age screen's VO₂max row. A day before the newest weekly score has none of its own.
    private func vo2max(fitness: FitnessResult, key: String) -> FitnessFactorItem? {
        guard let day = fitness.snapshot.latest?.day, day <= key else { return nil }
        let context = FitnessAgeFactorBuilder.Context(age: env.profile.age, sex: env.profile.sex,
                                                      snapshot: fitness.snapshot,
                                                      series: [.vo2max: fitness.vo2Series], now: now)
        return FitnessAgeFactorBuilder.items(context).first { $0.factor == .vo2max }
    }

    /// The Fasting screen's streak and 30-day consistency, as of the end of the selected day.
    private func fastingStreak() async -> MetricReadout {
        guard let store = await repo.storeHandle() else {
            return TodayBodyReadouts.fastingStreak(days: 0, metDays: 0, consideredDays: 0)
        }
        let intervals = await FastingLog.load(store: store, now: now).map(FastingInterval.init)
        let calendar = Calendar.current
        let dayEnd = calendar.date(byAdding: .second, value: 86_399, to: calendar.startOfDay(for: logicalDay)) ?? now
        let reference = isToday ? now : min(now, dayEnd)
        let streak = FastingEngine.streak(intervals, now: reference, calendar: calendar)
        let consistency = FastingEngine.consistency(intervals, now: reference, days: 30, calendar: calendar)
        return TodayBodyReadouts.fastingStreak(days: streak, metDays: consistency.metDays,
                                               consideredDays: consistency.consideredDays)
    }
}
#endif
