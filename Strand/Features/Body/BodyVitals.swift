#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Body vitals (CONCEPT §3.6 "Vitalwerte")
//
// The five nightly vitals as metric readouts: the freshest night (carried at most
// `Baselines.vitalCarryDays`), against the personal range folded from the nights before it, with a
// 30-day trend for the sparkline and the explainer. The readout itself comes from `SleepReadouts`, the
// one builder for "a nightly vital against your range", so these tiles and the Sleep page's night
// vitals can never disagree about the same night.

struct BodyVital: Identifiable, Equatable {
    let metric: SleepMetric
    var id: MetricID { metric.id }
    var readout: MetricReadout { metric.readout }
    var trend: [MetricExplanation.TrendPoint] { metric.explanation.trend }
    var isUnavailable: Bool {
        if case .unavailable = metric.readout.verdict { return true }
        return false
    }

    static func == (lhs: BodyVital, rhs: BodyVital) -> Bool {
        lhs.metric.readout == rhs.metric.readout && lhs.metric.explanation == rhs.metric.explanation
    }
}

enum BodyVitals {

    typealias Series = [(day: String, value: Double)]

    /// - Parameters:
    ///   - rows: source-tagged daily rows (imported wins over computed wins over Apple Health).
    ///   - overCountDays: nights whose HRV the strap over-counted (#1118); their HRV is not shown.
    static func build(rows: [SourcedDailyMetric], overCountDays: Set<String>, today: String) -> [BodyVital] {
        let hrv = series(rows, key: "hrv") { $0.avgHrv }.filter { !overCountDays.contains($0.day) }
        let rhr = series(rows, key: "rhr") { $0.restingHr.map(Double.init) }
        let resp = series(rows, key: "resp") { $0.respRateBpm }
        let spo2 = series(rows, key: "spo2") { $0.spo2Pct }
        // Skin temperature: the on-device deviation from baseline leads; imports that only carry the
        // absolute wrist temperature fall back to it with its own range.
        let skinDev = series(rows, key: "skin") { $0.skinTempDevC }.filter { !VitalBands.isAbsoluteSkinTemp($0.value) }
        let skinAbs = series(rows, key: "skin") { m in m.skinTempC ?? m.skinTempDevC.flatMap { VitalBands.isAbsoluteSkinTemp($0) ? $0 : nil } }
        let skinUsesDeviation = !skinDev.isEmpty || skinAbs.isEmpty

        return [
            vital(.hrv, SleepStrings.hrv, .milliseconds, hrv, SleepRangeConfig.hrv, SleepRangeConfig.hrvPopulation, today),
            vital(.restingHeartRate, SleepStrings.restingHR, .beatsPerMinute, rhr, SleepRangeConfig.restingHR,
                  SleepRangeConfig.restingHRPopulation, today),
            vital(.respiratoryRate, SleepStrings.respiratory, .breathsPerMinute, resp, SleepRangeConfig.respiratory,
                  SleepRangeConfig.respiratoryPopulation, today),
            vital(.spo2, SleepStrings.spo2, .percent, spo2, SleepRangeConfig.spo2, SleepRangeConfig.spo2Population, today),
            skinUsesDeviation
                ? vital(.skinTemperature, SleepStrings.skinTemp, .celsius, skinDev, SleepRangeConfig.skinDeviation,
                        SleepRangeConfig.skinPopulation, today)
                : vital(.skinTemperature, SleepStrings.skinTemp, .celsius, skinAbs, absoluteSkinCfg,
                        absoluteSkinPopulation, today),
        ]
    }

    /// Absolute wrist temperature while asleep (imports only); the population band is a typical
    /// night-time wrist range.
    static let absoluteSkinCfg = MetricCfg(minVal: 25, maxVal: 40, floorSpread: 0.15, halfLifeB: 14, halfLifeS: 21)
    static let absoluteSkinPopulation = 33.0...35.5

    private static func vital(_ id: MetricID, _ label: LocalizedStringResource, _ unit: MetricUnit,
                              _ points: Series, _ cfg: MetricCfg, _ population: ClosedRange<Double>,
                              _ today: String) -> BodyVital {
        let latest = Baselines.freshestCarried(points.map { (day: $0.day, value: $0.value) }, todayKey: today)
        let history = points.filter { latest == nil || $0.day < latest!.day }
        let metric = SleepReadouts.metric(id: id, label: label, value: latest?.value, unit: unit,
                                          history: history, cfg: cfg, population: population, tint: .neutral,
                                          valueDay: latest?.day)
        guard latest == nil else { return BodyVital(metric: metric) }
        // Nothing fresh: say since when, and keep the last 30 days for the trend.
        let since = points.last.map { BodyFormat.date($0.day) }
        let readout = MetricReadout(id: id, label: label, value: nil, unit: unit,
                                    verdict: .unavailable(.noData(since: since)),
                                    meaning: since == nil ? BodyStrings.vitalNeverMeasured : BodyStrings.vitalNotRecent,
                                    confidence: metric.readout.confidence, tint: .neutral)
        return BodyVital(metric: SleepMetric(readout: readout, explanation: metric.explanation))
    }

    /// One value per day, taking the first source (by precedence) that carries a value.
    static func series(_ rows: [SourcedDailyMetric], key: String, _ pick: (DailyMetric) -> Double?) -> Series {
        var byDay: [String: Double] = [:]
        for source in DailyMetricSource.vitalPrecedence(for: key) {
            for row in rows where row.source == source && byDay[row.metric.day] == nil {
                if let v = pick(row.metric), v.isFinite { byDay[row.metric.day] = v }
            }
        }
        return byDay.map { (day: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
    }

    // MARK: Interpretation of the set

    /// One sentence over all vitals, Apple Vitals style: one value out of range is noted calmly, two or
    /// more together are worth a look (CONCEPT §1 "calm by default", §5.7).
    static func summary(_ vitals: [BodyVital]) -> LocalizedStringResource? {
        let shown = vitals.filter { !$0.isUnavailable }
        guard !shown.isEmpty else { return nil }
        let outside = shown.filter { $0.readout.verdict == .above || $0.readout.verdict == .below }
        switch outside.count {
        case 0: return BodyStrings.vitalsAllTypical
        case 1: return BodyStrings.vitalsOneOutside(String(localized: outside[0].readout.label))
        default: return BodyStrings.vitalsSeveralOutside(outside.count)
        }
    }
}
#endif
