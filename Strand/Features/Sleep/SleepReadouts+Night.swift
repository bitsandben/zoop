import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

/// The numbers of one displayed night.
struct SleepNightMetrics {
    let score: SleepMetric
    let duration: SleepMetric
    let efficiency: SleepMetric
    /// Deep, REM, light, awake.
    let stages: [SleepMetric]
    let vitals: [SleepMetric]

    var all: [SleepMetric] { [score, duration, efficiency] + stages + vitals }
}

extension SleepReadouts {

    static func night(_ night: Night, hasStages: Bool, days: [DailyMetric],
                      imported: [String: ImportedSleepFigures]) -> SleepNightMetrics {
        let wakeDay = night.wakeDayKey
        let row = days.last { $0.day == wakeDay }
        let stages = night.stages
        func seconds(_ minutes: Double) -> Double? { hasStages ? minutes * 60 : nil }

        let duration = metric(id: SleepMetricID.duration, label: SleepStrings.duration,
                              value: seconds(stages.asleep), unit: .duration,
                              history: history(days, before: wakeDay) { $0.totalSleepMin.map { $0 * 60 } },
                              cfg: SleepRangeConfig.duration, population: SleepRangeConfig.durationPopulation,
                              valueDay: wakeDay)
        let efficiency = metric(id: SleepMetricID.efficiency, label: SleepStrings.efficiency,
                                value: hasStages && stages.total > 0 ? min(100, stages.asleep / stages.total * 100) : nil,
                                unit: .percent,
                                history: history(days, before: wakeDay) { efficiencyPct($0.efficiency) },
                                cfg: SleepRangeConfig.efficiency, population: SleepRangeConfig.efficiencyPopulation,
                                valueDay: wakeDay)
        return SleepNightMetrics(
            score: score(row: row, wakeDay: wakeDay, days: days, imported: imported),
            duration: duration,
            efficiency: efficiency,
            stages: stageMetrics(stages, hasStages: hasStages, wakeDay: wakeDay, days: days),
            vitals: vitals(row: row, wakeDay: wakeDay, days: days))
    }

    // MARK: Score

    private static func score(row: DailyMetric?, wakeDay: String, days: [DailyMetric],
                              imported: [String: ImportedSleepFigures]) -> SleepMetric {
        let value = imported[wakeDay]?.performancePct ?? row.flatMap { AnalyticsEngine.Rest.composite(daily: $0) }
        let hist = history(days, before: wakeDay) { score($0, imported: imported) }
        let range = SleepPersonalRange.resolve(history: hist.map { Optional($0.value) }, cfg: SleepRangeConfig.score,
                                               population: SleepRangeConfig.scorePopulation,
                                               lastSample: hist.last.map { date($0.day) })
        let readout: MetricReadout
        if let value {
            let band = ScoreBand(score: value)
            readout = MetricReadout(id: .sleepScore, label: SleepStrings.score, value: value, unit: .score,
                                    typicalRange: range.range, rangeIsPersonal: range.isPersonal,
                                    delta: range.baseline.map { value - $0 }, verdict: .score(band),
                                    meaning: SleepMeanings.score(band), confidence: range.confidence, tint: .sleep)
        } else {
            readout = MetricReadout(id: .sleepScore, label: SleepStrings.score, value: nil, unit: .score,
                                    verdict: .unavailable(.noData(since: hist.last.map { date($0.day) })),
                                    meaning: SleepStrings.noValueTonight, confidence: range.confidence, tint: .sleep)
        }
        let isImported = imported[wakeDay]?.performancePct != nil
        return SleepMetric(readout: readout,
                           explanation: explanation(.sleepScore, range: range, history: hist,
                                                    tonight: value.map { (wakeDay, $0) },
                                                    contributors: isImported ? [] : contributors(row),
                                                    extraReason: isImported ? SleepStrings.importedScoreReason : nil))
    }

    /// Which composite terms lifted or lowered the night: a term near full marks raises, one in its
    /// lower half lowers. Thresholds are display bands, not part of the score.
    private static func contributors(_ row: DailyMetric?) -> [MetricExplanation.Contributor] {
        guard let row, let tst = row.totalSleepMin, tst > 0, let eff = row.efficiency else { return [] }
        let terms = AnalyticsEngine.Rest.terms(
            tstSeconds: tst * 60, efficiency: eff <= 1 ? eff : eff / 100,
            restorativeSeconds: ((row.deepMin ?? 0) + (row.remMin ?? 0)) * 60,
            needHours: AnalyticsEngine.Rest.defaultNeedHours, consistency: nil,
            deepSeconds: (row.deepMin ?? 0) * 60)
        func effect(_ term: Double) -> MetricExplanation.Contributor.Effect {
            term >= 0.8 ? .raises : (term < 0.5 ? .lowers : .neutral)
        }
        return [
            .init(id: "duration", label: SleepExplanations.contributorDuration, effect: effect(terms.duration)),
            .init(id: "efficiency", label: SleepExplanations.contributorEfficiency, effect: effect(terms.efficiency)),
            .init(id: "restorative", label: SleepExplanations.contributorRestorative, effect: effect(terms.restorative)),
        ]
    }

    // MARK: Stages

    private static func stageMetrics(_ s: Stages, hasStages: Bool, wakeDay: String,
                                     days: [DailyMetric]) -> [SleepMetric] {
        func stage(_ id: MetricID, _ label: LocalizedStringResource, _ minutes: Double,
                   _ pick: (DailyMetric) -> Double?, _ population: ClosedRange<Double>) -> SleepMetric {
            metric(id: id, label: label, value: hasStages ? minutes * 60 : nil, unit: .duration,
                   history: history(days, before: wakeDay) { pick($0).map { $0 * 60 } },
                   cfg: SleepRangeConfig.stage, population: population, valueDay: wakeDay)
        }
        return [
            stage(SleepMetricID.deep, SleepStrings.deep, s.deep, \.deepMin, SleepRangeConfig.deepPopulation),
            stage(SleepMetricID.rem, SleepStrings.rem, s.rem, \.remMin, SleepRangeConfig.remPopulation),
            stage(SleepMetricID.light, SleepStrings.light, s.light, \.lightMin, SleepRangeConfig.lightPopulation),
            stage(SleepMetricID.awake, SleepStrings.awake, s.awake, awakeMin, SleepRangeConfig.awakePopulation),
        ]
    }

    // MARK: Vitals

    private static func vitals(row: DailyMetric?, wakeDay: String, days: [DailyMetric]) -> [SleepMetric] {
        func vital(_ id: MetricID, _ label: LocalizedStringResource, _ unit: MetricUnit, _ cfg: MetricCfg,
                   _ population: ClosedRange<Double>, _ pick: (DailyMetric) -> Double?) -> SleepMetric {
            metric(id: id, label: label, value: row.flatMap(pick), unit: unit,
                   history: history(days, before: wakeDay, pick), cfg: cfg, population: population,
                   tint: .neutral, valueDay: wakeDay)
        }
        var out = [
            vital(.hrv, SleepStrings.hrv, .milliseconds, SleepRangeConfig.hrv, SleepRangeConfig.hrvPopulation) { $0.avgHrv },
            vital(.restingHeartRate, SleepStrings.restingHR, .beatsPerMinute, SleepRangeConfig.restingHR,
                  SleepRangeConfig.restingHRPopulation) { $0.restingHr.map(Double.init) },
            vital(.respiratoryRate, SleepStrings.respiratory, .breathsPerMinute, SleepRangeConfig.respiratory,
                  SleepRangeConfig.respiratoryPopulation) { $0.respRateBpm },
        ]
        // Blood oxygen and skin temperature only for straps that have ever reported them.
        if days.contains(where: { $0.spo2Pct != nil }) {
            out.append(vital(.spo2, SleepStrings.spo2, .percent, SleepRangeConfig.spo2,
                             SleepRangeConfig.spo2Population) { $0.spo2Pct })
        }
        if days.contains(where: { $0.skinTempDevC != nil }) {
            out.append(vital(.skinTemperature, SleepStrings.skinTemp, .temperatureDeviation(UnitPrefs.currentMetricTemperatureSystem()), SleepRangeConfig.skinDeviation,
                             SleepRangeConfig.skinPopulation) { $0.skinTempDevC })
        }
        return out
    }
}
