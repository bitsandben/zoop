import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// One smart-alarm check's evidence: asks the strap for a sync, then reads the night so far from the store.
/// Every value is what the app could see at that moment; nothing is inferred about data it did not receive.
@MainActor
enum SmartWakeProbe {

    /// How far back "tonight" reaches.
    static let lookbackS = 14 * 3600

    struct Reading {
        var inputs: GoalWake.Inputs
        var hrAgeS: Int?
        var gravityAgeS: Int?
        var signal: SmartWake.Signal?
        var estimate: PartialNightRecovery.Estimate?
        /// The night's sleeping heart-rate level the live read compares against (`LiveWake.sleepingLevel`).
        var sleepingBpm: Double?
    }

    /// The sleeping level leaves out the last few minutes, so a rise now does not lift its own baseline.
    static let sleepingLevelHoldOffS = 10 * 60

    // MARK: Sync

    /// Requests a sync and waits up to `settle` seconds for it to finish. The result names only what the
    /// sync path itself reported: the history-complete stamp, a sync that ended without it, or none at all.
    static func sync(model: AppModel, settle: TimeInterval) async -> SmartAlarmNight.SyncResult {
        let live = model.live
        guard live.connected else { return .noStrap }
        let before = live.lastSyncedAt ?? 0
        let wasRunning = live.backfilling
        model.ble.requestSync(.manual)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard wasRunning || live.backfilling || (live.lastSyncedAt ?? 0) > before else { return .notStarted }
        let until = Date().addingTimeInterval(settle)
        while Date() < until, live.backfilling, (live.lastSyncedAt ?? 0) <= before {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if (live.lastSyncedAt ?? 0) > before { return .completed }
        return live.backfilling ? .timedOut : .failed
    }

    // MARK: Night so far

    /// The inputs for one decision at `now` for the night ending at `deadline`. `needMin` is tonight's need as
    /// recorded when the night was set up.
    static func read(model: AppModel, now: Int, deadline: Int, needMin: Double?) async -> Reading {
        let repo = model.repo
        let from = now - lookbackS
        let cap = Int(Double(lookbackS) * StreamReadCap.headroom)
        let hr = await repo.hrSamples(from: from, to: now, limit: cap)
        let rr = await repo.rrIntervals(from: from, to: now, limit: cap * 2)
        let gravity = await repo.gravitySamplesUnion(from: from, to: now, limit: cap)
        let signal = SmartWake.lightSleepSignal(hr: hr, gravity: gravity, now: now)
        let sessions = await detect(hr: hr, rr: rr, gravity: gravity,
                                    tz: TimeZone.current.secondsFromGMT(),
                                    v2: PuffinExperiment.experimentalSleepV2Enabled)
        let progress = NightProgress.tonight(sessions: sessions, now: now)
        let before = days(repo.days, beforeWake: deadline)
        let need = needMin ?? sleepTargetMin(days: before)
        let base = baselines(before)
        let estimate = progress.flatMap {
            PartialNightRecovery.estimate(hrvSoFar: $0.hrv, restingHRSoFar: $0.restingHR, asleepMin: $0.asleepMin,
                                          needMin: need, hrvBaseline: base.hrv, rhrBaseline: base.rhr)
        }
        let inputs = GoalWake.Inputs(now: now, asleepMin: progress?.asleepMin, needMin: need,
                                     recovery: estimate?.score, lightSleep: signal != nil)
        return Reading(inputs: inputs,
                       hrAgeS: hr.map(\.ts).max().map { now - $0 },
                       gravityAgeS: gravity.map(\.ts).max().map { now - $0 },
                       signal: signal, estimate: estimate,
                       sleepingBpm: LiveWake.sleepingLevel(hr, from: progress?.onset ?? from,
                                                           to: now - sleepingLevelHoldOffS))
    }

    /// The sleep detector, off the main actor (it sorts a night of motion).
    nonisolated static func detect(hr: [HRSample], rr: [RRInterval], gravity: [GravitySample],
                                   tz: Int, v2: Bool) async -> [SleepSession] {
        SleepStager.detectSleep(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tz, useSleepStagerV2: v2)
    }

    // MARK: Shared resolvers

    /// Tonight's sleep need from the day history: the planner's Tonight card reads the same function.
    static func needTonight(days: [DailyMetric]) -> SleepDebt.NeedTonight {
        let need = SleepModel.debtNeedMin(days: days)
        let ledger = SleepModel.debtLedger(days: days, napSleepMinByDay: [:])
        let strain21 = days.last?.strain.map { $0 * 0.21 }
        return SleepDebt.needTonight(baseNeedMin: need, strain21: strain21,
                                     debtMin: ledger.isDebt ? ledger.magnitudeMin : 0)
    }

    /// The asleep minutes the sleep-need mode waits for: tonight's need times the planner's goal
    /// ("Tomorrow I want to …", 100 / 85 / 70 %), the same share the planner's bedtime is built from.
    static func sleepTargetMin(days: [DailyMetric]) -> Double {
        #if os(iOS)
        let goal = SleepGoal.current.fraction
        #else
        let goal = 1.0
        #endif
        return needTonight(days: days).totalMin * goal
    }

    /// Days before the wake day: in the evening that includes today (as the Tonight card reads it); after
    /// midnight the new, still empty day is left out, so the need and baselines stay those of the evening.
    static func days(_ days: [DailyMetric], beforeWake deadline: Int) -> [DailyMetric] {
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(deadline)))
        return days.filter { $0.day < wakeDay }
    }

    /// HRV and resting-HR baselines over past nights, folded the way the recovery engine folds them.
    static func baselines(_ days: [DailyMetric]) -> (hrv: BaselineState?, rhr: BaselineState?) {
        guard !days.isEmpty else { return (nil, nil) }
        let hrv = Baselines.foldHistory(days.map(\.avgHrv), dayKeys: days.map(\.day), cfg: Baselines.hrvCfg)
        let rhr = Baselines.foldHistory(days.map { $0.restingHr.map(Double.init) }, cfg: Baselines.restingHRCfg)
        return (hrv, rhr.usable ? rhr : nil)
    }
}
