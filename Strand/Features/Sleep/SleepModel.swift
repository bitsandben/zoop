import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - SleepModel
//
// The memoised derivation behind the Sleep screen: the newest night resolved once, plus the
// night-independent series. `build(_:)` is a pure function of `SleepModelInputs`, so Today's hosted
// sleep cards build the identical model without the screen.

struct SleepModel {
    /// (latest, latestDay, typical mean, full history). `latestDay` is set only when `latest` was carried
    /// from an earlier day, so a prior night's number is never passed off as tonight's.
    typealias Metric = (latest: Double?, latestDay: String?, typical: Double?, series: [Double])

    /// "Carried · 12 Jul" for a value carried from an earlier day; nil for today's own value.
    static func carriedMetricCaption(latestDay: String?, latest: Double?) -> String? {
        guard let latestDay, latest != nil else { return nil }
        return String(localized: "Carried · \(Self.shortDayLabel(latestDay))")
    }

    /// "12 Jul" for a "yyyy-MM-dd" key.
    static func shortDayLabel(_ key: String) -> String {
        guard let date = dayKeyParser.date(from: key) else { return key }
        return Self.shortDayFormatter.string(from: date)
    }

    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    let night: Night
    /// `night.intervals`, resolved once.
    let intervals: [SleepInterval]
    /// True when `intervals` are the stager's stored segments rather than a drawn approximation.
    let isPersistedHypnogram: Bool
    /// True when the newest day decoded to no stages (e.g. a hand edit staged all-awake). The screen
    /// then shows that night without stages instead of going blank, so it stays editable.
    let isStubNight: Bool

    let performance: Metric
    let efficiency: Metric
    let consistency: Metric
    let hoursVsNeeded: Metric
    let restorative: Metric
    let respiratory: Metric
    let sleepDebt: Metric
    /// Wake-ups per night (`DailyMetric.disturbances`).
    let wakeUps: Metric

    let typicalTotalMin: Double?
    let typicalDeepMin: Double?
    let typicalRemMin: Double?
    let typicalLightMin: Double?
    /// Each stage's typical share of time in bed (25th–75th percentile, trailing 30 nights).
    let stageShareBands: StageShareBands.Bands

    let trendPoints: [TrendPoint]

    /// Recency-weighted sleep debt over the latest 14 usable nights.
    let sleepDebtLedger: SleepDebtLedger
    /// The debt after each night, keyed by day, oldest first.
    let sleepDebtHistory: [(day: String, value: Double)]
}

/// A snapshot of the repository state `SleepModel.build(_:)` reads.
struct SleepModelInputs {
    /// The cached per-day metric rows (`Repository.days`).
    let days: [DailyMetric]
    /// One session per night (`Repository.sleeps`): the fallback until `allSessions` loads.
    let sleeps: [CachedSleepSession]
    /// Every stored sleep block, naps and split nights included; empty until loaded.
    let allSessions: [CachedSleepSession]
    /// Per-day imported WHOOP figures, used verbatim where present.
    let importedSleep: [String: ImportedSleepFigures]
    /// The learned habitual midsleep (local seconds) the engine threaded into the daily totals.
    let habitualMidsleepSec: Int?
    /// Per-epoch motion keyed by detected block start.
    let motionByStart: [Int: [Double]]
}

// MARK: - Night navigation
extension SleepModel {

    /// Every block grouped by the day it ends on (the dashboard's per-night merge), newest day first,
    /// blocks oldest first. Each day is one navigation stop.
    static func navDays(navSessions: [CachedSleepSession]) -> [[CachedSleepSession]] {
        let cal = Calendar.current
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        let groups = Dictionary(grouping: navSessions, by: endDay)
        return groups.keys.sorted(by: >).map { key in
            (groups[key] ?? []).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        }
    }

    /// The displayed bedtime: the first fragment that is not a pre-onset awake stub.
    static func nightOnsetTs(_ group: [CachedSleepSession]) -> Int {
        guard let first = group.first else { return 0 }
        let refAsleepMin = group.map {
            SleepScreen.decodedAsleepMinutes($0.stagesJSON, effectiveStartTs: $0.effectiveStartTs)
        }.max() ?? 0
        for frag in group {
            if !isPreOnsetAwakeStub(frag, refAsleepMin: refAsleepMin) { return frag.effectiveStartTs }
        }
        return first.effectiveStartTs
    }

    /// Fragment-level stub test over the decoded span and asleep minutes.
    static func isPreOnsetAwakeStub(_ frag: CachedSleepSession, refAsleepMin: Double = 0) -> Bool {
        let spanMin = Double(frag.endTs - frag.effectiveStartTs) / 60.0
        let asleepMin = SleepScreen.decodedAsleepMinutes(frag.stagesJSON,
                                                       effectiveStartTs: frag.effectiveStartTs)
        return SleepScreen.isPreOnsetAwakeStub(spanMin: spanMin, asleepMin: asleepMin, refAsleepMin: refAsleepMin)
    }

    /// The day's main-night group merged into one `Night`, bridged the way `AnalyticsEngine.analyzeDay`
    /// bridges it; gaps between fragments become awake segments. nil when nothing decodes to sleep.
    static func mergeDay(_ sessions: [CachedSleepSession],
                         habitualMidsleepSec: Int?,
                         motionByStart: [Int: [Double]]) -> Night? {
        let fullGroup = SleepScreen.mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
        guard let last = fullGroup.last else { return nil }
        let onset = nightOnsetTs(fullGroup), wake = last.endTs
        let group = fullGroup.drop { $0.effectiveStartTs < onset }
        var stages = Stages.zero
        var segs: [SleepInterval] = []
        var motion: [Double] = []
        for frag in group {
            if let seg = SleepScreen.decodeSegments(frag.stagesJSON, sessionStart: frag.effectiveStartTs), seg.stages.total > 0 {
                stages.awake += seg.stages.awake; stages.light += seg.stages.light
                stages.deep  += seg.stages.deep;  stages.rem   += seg.stages.rem
                let shift = TimeInterval(frag.effectiveStartTs - onset)
                for iv in seg.intervals {
                    segs.append(SleepInterval(stage: iv.stage, start: iv.start + shift, end: iv.end + shift))
                }
            } else if let st = SleepScreen.decodeStages(frag.stagesJSON), st.total > 0 {
                stages.awake += st.awake; stages.light += st.light
                stages.deep  += st.deep;  stages.rem   += st.rem
            }
            if let m = motionByStart[frag.startTs] { motion.append(contentsOf: m) }
        }
        let orderedFrags = Array(group)
        for (prev, next) in zip(orderedFrags, orderedFrags.dropFirst()) {
            let gapStart = prev.endTs, gapEnd = next.effectiveStartTs
            guard gapEnd > gapStart else { continue }
            segs.append(SleepInterval(stage: .awake,
                                      start: TimeInterval(gapStart - onset),
                                      end: TimeInterval(gapEnd - onset)))
        }
        guard stages.asleep > 0 else { return nil }
        let eff = stages.total > 0 ? stages.asleep / stages.total : nil
        let synth = CachedSleepSession(startTs: onset, endTs: wake, efficiency: eff,
                                       restingHr: nil, avgHrv: nil, stagesJSON: nil)
        let realSegs = segs.count >= 2 ? segs.sorted { $0.start < $1.start } : nil
        return Night(session: synth, stages: stages, realSegments: realSegs, sourceBlocks: sessions,
                     motionEpochs: motion, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The merged night `offset` stops back from the newest (0 = last night).
    static func decodedNight(at offset: Int, navDays: [[CachedSleepSession]],
                             habitualMidsleepSec: Int?, motionByStart: [Int: [Double]]) -> Night? {
        guard offset >= 0, offset < navDays.count else { return nil }
        return mergeDay(navDays[offset], habitualMidsleepSec: habitualMidsleepSec, motionByStart: motionByStart)
    }

    /// Asleep nap minutes per wake day, from the same grouping and main-night selector as the screen.
    static func napSleepMinutesByDay(navDays: [[CachedSleepSession]], habitualMidsleepSec: Int?) -> [String: Double] {
        var result: [String: Double] = [:]
        for blocks in navDays {
            guard let endTs = blocks.first?.endTs else { continue }
            let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(endTs)))
            result[day] = SleepScreen.napSleepMinutes(blocks, habitualMidsleepSec: habitualMidsleepSec)
        }
        return result
    }

    /// Every derivation, once, as a pure function of `inputs`. nil only when no day has any block.
    static func build(_ inputs: SleepModelInputs) -> SleepModel? {
        let navSessions = inputs.allSessions.isEmpty ? inputs.sleeps : inputs.allSessions
        let dayGroups = navDays(navSessions: navSessions)
        let habitual = inputs.habitualMidsleepSec

        // One undecodable newest day must not blank the screen: show it without stages instead.
        let night: Night
        let isStub: Bool
        if let merged = decodedNight(at: 0, navDays: dayGroups,
                                     habitualMidsleepSec: habitual, motionByStart: inputs.motionByStart) {
            night = merged
            isStub = false
        } else {
            let blocks0 = dayGroups.indices.contains(0) ? dayGroups[0] : []
            if let stubSession = SleepScreen.stubDaySession(blocks0, habitualMidsleepSec: habitual) {
                night = Night(session: stubSession, stages: .zero,
                              sourceBlocks: blocks0, habitualMidsleepSec: habitual)
                isStub = true
            } else {
                return nil
            }
        }

        let napSleepMinByDay = napSleepMinutesByDay(navDays: dayGroups, habitualMidsleepSec: habitual)
        return SleepModel(
            night: night,
            intervals: night.intervals,
            isPersistedHypnogram: (night.realSegments?.count ?? 0) >= 2,
            isStubNight: isStub,
            performance: performanceSeries(days: inputs.days, importedSleep: inputs.importedSleep),
            efficiency: efficiencySeries(days: inputs.days),
            consistency: consistencySeries(days: inputs.days, sleeps: inputs.sleeps, importedSleep: inputs.importedSleep),
            hoursVsNeeded: hoursVsNeededSeries(days: inputs.days, importedSleep: inputs.importedSleep),
            restorative: restorativeSeries(days: inputs.days),
            respiratory: respiratorySeries(days: inputs.days),
            sleepDebt: sleepDebtSeries(days: inputs.days, importedSleep: inputs.importedSleep,
                                       napSleepMinByDay: napSleepMinByDay),
            wakeUps: metric(days: inputs.days) { $0.disturbances.map(Double.init) },
            typicalTotalMin: typicalTotalMin(days: inputs.days),
            typicalDeepMin: typicalStageMin(days: inputs.days, \.deepMin),
            typicalRemMin: typicalStageMin(days: inputs.days, \.remMin),
            typicalLightMin: typicalStageMin(days: inputs.days, \.lightMin),
            stageShareBands: StageShareBands.bands(inputs.days.suffix(30).map {
                StageShareBands.Night(lightMin: $0.lightMin, deepMin: $0.deepMin,
                                      remMin: $0.remMin, efficiency: $0.efficiency)
            }),
            trendPoints: durationTrendPoints(days: inputs.days),
            sleepDebtLedger: debtLedger(days: inputs.days, napSleepMinByDay: napSleepMinByDay),
            sleepDebtHistory: sleepDebtHistory(days: inputs.days, importedSleep: inputs.importedSleep,
                                               napSleepMinByDay: napSleepMinByDay))
    }
}
