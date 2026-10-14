#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

/// One Today load: reads the repository for one day and turns it into `TodayContent`. Every read
/// lands in a local first; the model writes the result in one assignment.
@MainActor
struct TodayLoader {
    let env: TodayEnvironment
    let offset: Int
    let now: Date

    struct Loaded {
        let content: TodayContent
        let explanations: TodayExplanations.Inputs
        let stressHours: [DaytimeStress.HourPoint]
    }

    struct Live {
        let stress: MetricReadout
        let energy: MetricReadout?
        let moment: TodayMoment?
        let stressHours: [DaytimeStress.HourPoint]
        let daily: DaytimeStress.Daily?
    }

    var repo: Repository { env.repo }
    var isToday: Bool { offset == 0 }
    var logicalDay: Date { TodayModel.logicalDay(offset: offset, now: now) }

    /// Today follows the repository's own today row (it can lead the clock right after the rollover).
    var dayKey: String {
        if isToday, let key = repo.today?.day { return key }
        return Repository.localDayKey(logicalDay)
    }

    func load() async -> Loaded {
        let key = dayKey
        let row = isToday ? (repo.today ?? repo.days.last { $0.day == key }) : repo.days.last { $0.day == key }

        let recoveryDisplay = recoveryDisplay(row: row, key: key)
        let carriedRow = recoveryDisplay.carriedDay.flatMap { day in repo.days.last { $0.day == day } }
        let strainNow = isToday ? await liveStrain(row: row) : (value: nil, samples: nil)
        let strainValue = StrainScorer.effectiveEffort(live: strainNow.value, stored: row?.strain)
        let recoveryPct = recoveryDisplay.pct

        let live = await liveParts(key: key)
        let activities = await activities(key: key)
        let dashboard = await dashboard(key: key, row: row)
        let fitness = await fitnessAge(key: key)
        let explanations = await explanationInputs(key: key, scoreRow: carriedRow ?? row,
                                                   stressTrend: live.daily?.trend ?? [],
                                                   dashboard: dashboard, fitness: fitness.history)

        let content = TodayContent(
            dayKey: key, isToday: isToday,
            sleep: TodayRings.sleep(sleepNight(onOrBefore: key), selectedDay: key, isToday: isToday),
            recovery: TodayRings.recovery(recoveryDisplay, hrvBaseline: repo.chargeBaselines?.hrv),
            strain: TodayRings.strain(strainValue, whoopScale: env.whoopScale, hrSamples: strainNow.samples),
            strainRingMax: env.whoopScale ? 21 : 100,
            strainTarget: isToday ? TodayRings.strainTarget(recovery: recoveryPct) : nil,
            strainTargetCaption: isToday ? TodayRings.strainTargetCaption(
                recovery: recoveryPct, whoopScale: env.whoopScale, locale: AppLanguage.activeLocale) : nil,
            synthesis: TodayRings.synthesis(recoveryDisplay, isToday: isToday),
            greeting: greeting(),
            stress: live.stress,
            health: healthSummary(key: key),
            energy: live.energy,
            checkIn: await checkIn(),
            moment: live.moment,
            activities: activities,
            showsCycle: env.profile.cycleAwarenessApplies
                && !UserDefaults.standard.bool(forKey: AppModel.cycleAwarenessHiddenKey),
            dashboard: dashboard.readouts,
            fitnessAge: fitness.readout)
        return Loaded(content: content, explanations: explanations, stressHours: live.stressHours)
    }

    // MARK: Recovery

    private func recoveryDisplay(row: DailyMetric?, key: String) -> RecoveryDisplay {
        let history = repo.chargeBaselines?.hrvHistory
        let calibrationNights = isToday
            ? RecoveryScorer.calibrationNights(nightlyHrv: history?.values ?? [], dayKeys: history?.dayKeys ?? [],
                                               hasRecovery: row?.recovery != nil)
            : nil
        let prior = TodayLogic.lastScoredRecoveryDay(days: repo.days, selectedDayKey: key, isToday: isToday,
                                                     todayScored: row?.recovery != nil,
                                                     isCalibrating: calibrationNights != nil)
        return RecoveryDisplay.resolve(todayRecovery: row?.recovery, priorScored: prior,
                                       calibrationNights: calibrationNights)
    }

    // MARK: Sleep

    /// The night the Sleep screen leads with for this day: the newest stored night that woke on or
    /// before it, scored by the same rule as `SleepView.performanceScore`.
    func sleepNight(onOrBefore key: String) -> TodayRings.SleepNight? {
        let wakeDays = repo.sleeps.map { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) }
        guard let wakeDay = wakeDays.filter({ $0 <= key }).max() else { return nil }
        let score = TodayRings.sleepScore(wakeDay: wakeDay, importedPct: repo.importedSleep[wakeDay]?.performancePct,
                                          row: repo.days.last { $0.day == wakeDay })
        return TodayRings.SleepNight(wakeDay: wakeDay, score: score)
    }

    // MARK: Strain

    /// Today's in-progress strain over the same window the daily pass scores (#1001), with the sample
    /// count that sets its confidence. The explicit limit matters: `hrSamples` is oldest-first, so the
    /// chart-sized default would drop the newest hours of a full day.
    private func liveStrain(row: DailyMetric?) async -> (value: Double?, samples: Int?) {
        let window = await dayWindow()
        let hr = await repo.hrSamples(from: window.lowerBound, to: window.upperBound, limit: 200_000)
        let maxHR = env.profile.effortHRmax
        let restHR = row?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        let method = PuffinExperiment.effortMethod
        let sex = env.profile.sex
        let value = await Task.detached(priority: .utility) {
            StrainScorer.strain(hr, maxHR: maxHR, restingHR: restHR, method: method, sex: sex)
        }.value
        return (value, hr.count)
    }

    /// Midnight to now, or from the night's sleep onset when the day-cycle setting asks for it.
    private func dayWindow() async -> ClosedRange<Int> {
        let start = Calendar.current.startOfDay(for: logicalDay)
        let from = Int(start.timeIntervalSince1970)
        let to = Int(now.timeIntervalSince1970)
        guard env.dayCycleMode == .sleepOnset else { return from...max(from, to) }
        let markers = await repo.exploreSeries(key: DayCycleIntelligenceIntegration.onsetKey, source: "my-whoop")
        let onset = markers.last { $0.day == dayKey }.map { Int($0.value) } ?? from
        return onset...max(onset, to)
    }

    // MARK: Stress, Energy Bank and the moment card

    func liveParts() async -> Live { await liveParts(key: dayKey) }

    private func liveParts(key: String) async -> Live {
        let stored = await repo.series(key: "stress", source: "my-whoop")
        let days = repo.days.filter { $0.day <= key }
        let storedUpTo = stored.filter { $0.day <= key }
        let daily = await Task.detached(priority: .utility) {
            DaytimeStress.daily(days: days, stored: storedUpTo)
        }.value
        guard isToday else {
            let headline = TodayBodyReadouts.pastDayStress(daily, dayKey: key)
            return Live(stress: TodayBodyReadouts.stress(headline), energy: nil, moment: nil,
                        stressHours: [], daily: daily)
        }
        let hours = await StressDayCurve.today(
            repo: repo, personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled)?.result.timeline ?? []
        let headline = DaytimeStress.headline(hours: hours, daily: daily)
        let energy = await EnergyBankDay.today(repo: repo, maxHR: env.profile.effortHRmax, now: now)
        return Live(stress: TodayBodyReadouts.stress(headline),
                    energy: TodayBodyReadouts.energy(energy),
                    moment: await moment(hours: hours), stressHours: hours, daily: daily)
    }

    private func moment(hours: [DaytimeStress.HourPoint]) async -> TodayMoment? {
        let nowTs = Int(now.timeIntervalSince1970)
        let recent = await repo.hrSamples(from: nowTs - 600, to: nowTs, limit: 2_000)
        // Twenty samples is the least that reads as "the last ten minutes" rather than one blip.
        let recentHR = recent.count >= 20 ? Double(recent.map(\.bpm).reduce(0, +)) / Double(recent.count) : nil
        switch TodayMoment.pick(now: now, hours: hours, recentHR: recentHR) {
        case .breathe: return .breathe
        case .evening:
            let alarm = AppModel.shared?.nextArmedStrapAlarm(from: now)
            let patterns = PatternsModel()
            await patterns.loadQuick(repo: repo, alarm: alarm)
            // The planner reports the bedtime in seconds of the day.
            return .evening(bedtimeMinute: patterns.tonight?.bedtime.map { $0 / 60 }, alarm: alarm)
        case nil: return nil
        }
    }

    // MARK: Health monitor

    /// The vitals as they stood on this day: rows after it are dropped and the carry is judged from it.
    private func healthSummary(key: String) -> TodayHealthSummary {
        let rows = repo.vitalMetricRows.filter { $0.metric.day <= key }
        let reference = isToday ? now : Calendar.current.date(byAdding: .hour, value: 12, to: logicalDay) ?? logicalDay
        let readings = BodyVitalSigns.readings(sourceRows: rows, temperatureUnit: env.temperatureUnit, now: reference)
        let vitals = readings
            .filter { $0.banding.band != .noData && $0.key != "spo2raw" }
            .map { TodayHealthSummary.Vital(id: $0.key, name: Self.shortName($0.key),
                                            inRange: $0.banding.band == .inRange) }
        return TodayHealthSummary(vitals: vitals)
    }

    /// Short tags so five vitals fit half a screen width.
    static func shortName(_ key: String) -> String {
        switch key {
        case "hrv": return "HRV"
        case "rhr": return String(localized: "vital.short.rhr", defaultValue: "RHR")
        case "resp": return String(localized: "vital.short.resp", defaultValue: "Resp")
        case "spo2": return "SpO₂"
        case "skin": return String(localized: "vital.short.temp", defaultValue: "Temp")
        default: return key.uppercased()
        }
    }

    // MARK: Check-in and greeting

    private func checkIn() async -> TodayCheckIn {
        guard isToday else { return .hidden }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: RecoveryCalibrationStore.enabledKey) else {
            return defaults.bool(forKey: RecoveryCalibrationStore.inviteDismissedKey) ? .hidden : .invite
        }
        // The check-in is filed under the calendar day it was answered, as `MorningCheckInSheet` saves it.
        let day = Repository.dayString(now)
        guard let store = await repo.storeHandle() else { return .hidden }
        let answered = await RecoveryCalibrationStore.checkIns(store: store, from: day, to: day)[day] != nil
        return answered ? .hidden : .ask
    }

    /// Pastel greets by first name on today; Classic lets the rings speak.
    private func greeting() -> LocalizedStringResource? {
        guard isToday, ZoopTheme.isPastel else { return nil }
        let first = env.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? ""
        guard !first.isEmpty else { return nil }
        let hour = Calendar.current.component(.hour, from: now)
        let part: DayPart = hour < 11 ? .morning : (hour < 18 ? .day : .evening)
        return TodayCopy.greeting(part, name: first)
    }
}

extension RecoveryDisplay {
    /// The day a carried score came from.
    var carriedDay: String? {
        if case .carried(_, let day) = self { return day }
        return nil
    }
}
#endif
