import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

/// The rolling, night-independent Sleep numbers: debt and regularity, as of the newest night.
struct SleepOverviewMetrics {
    let debt: SleepMetric
    /// Each counted night's slept − need, oldest first, for the debt bars.
    let debtNights: [SleepDebtNight]
    let regularity: SleepMetric
}

extension SleepReadouts {

    static func overview(model: SleepModel, windows: [(start: Int, end: Int)],
                         newestWake: Date) -> SleepOverviewMetrics {
        SleepOverviewMetrics(debt: debt(model: model),
                             debtNights: model.sleepDebtLedger.nights,
                             regularity: regularity(windows: windows, newestWake: newestWake))
    }

    // MARK: Debt

    /// Debt now, against the debts of earlier nights. The meaning names tonight's target: the need plus
    /// the ledger's carry share of the debt, capped at the engine's maximum need (CONCEPT §5.1).
    private static func debt(model: SleepModel) -> SleepMetric {
        let ledger = model.sleepDebtLedger
        let debtMin = ledger.isDebt ? ledger.magnitudeMin : 0
        let needMin = ledger.needMin
        let tonightMin = min(AnalyticsEngine.Rest.maxNeedHours * 60, needMin + SleepDebt.debtCarryFactor * debtMin)
        let meaning: LocalizedStringResource = debtMin >= SleepDebt.minimumDebtMin
            ? SleepStrings.debtSome(durationText(seconds: tonightMin * 60))
            : SleepStrings.debtNone(durationText(seconds: needMin * 60))
        let keyed = model.sleepDebtHistory
        let hist: History = keyed.dropLast().map { ($0.day, $0.value * 60) }
        return metric(id: SleepMetricID.debt, label: SleepStrings.debt,
                      value: ledger.nightCount > 0 ? debtMin * 60 : nil, unit: .duration,
                      history: hist, cfg: SleepRangeConfig.debt, population: SleepRangeConfig.debtPopulation,
                      valueDay: keyed.last?.day, meaning: { _ in meaning })
    }

    // MARK: Regularity

    /// SRI over the last 14 days, against the SRI of the trailing windows before it.
    private static func regularity(windows: [(start: Int, end: Int)], newestWake: Date) -> SleepMetric {
        let series = SleepRegularity.trailingSeries(windows: windows, endDay: newestWake, count: 30)
        let keyed: History = series.compactMap { entry in
            entry.index.map { (Repository.localDayKey(entry.day), $0) }
        }
        let current = SleepRegularity.compute(windows: windows, endDay: newestWake)
        let hist = Array(keyed.dropLast())
        let range = SleepPersonalRange.resolve(history: hist.map { Optional($0.value) }, cfg: SleepRangeConfig.regularity,
                                               population: SleepRangeConfig.regularityPopulation,
                                               lastSample: hist.last.map { date($0.day) })
        let readout: MetricReadout
        if let current {
            let band = ScoreBand(score: current.index)
            let midpoint = clockText(minutes: current.midpointMin)
            let meaning: LocalizedStringResource
            switch band {
            case .high: meaning = SleepStrings.regularityHigh(midpoint)
            case .medium: meaning = SleepStrings.regularityMedium(midpoint)
            case .low: meaning = SleepStrings.regularityLow(midpoint)
            }
            readout = MetricReadout(id: SleepMetricID.regularity, label: SleepStrings.regularity,
                                    value: current.index, unit: .score, typicalRange: range.range,
                                    rangeIsPersonal: range.isPersonal, delta: range.baseline.map { current.index - $0 },
                                    verdict: .score(band), meaning: meaning, confidence: range.confidence, tint: .sleep)
        } else {
            let worn = recordedDays(windows: windows, endDay: newestWake)
            let left = max(1, SleepRegularity.minDayPairs + 1 - worn)
            readout = MetricReadout(id: SleepMetricID.regularity, label: SleepStrings.regularity, value: nil,
                                    unit: .score, verdict: .unavailable(.calibrating(nightsLeft: left)),
                                    meaning: SleepStrings.regularityPending, confidence: .calibrating(nightsLeft: left),
                                    tint: .sleep)
        }
        return SleepMetric(readout: readout,
                           explanation: explanation(SleepMetricID.regularity, range: range, history: hist,
                                                    tonight: current.map { (keyed.last?.day ?? "", $0.index) }))
    }

    /// Distinct wake days with a recorded window in the regularity window, for the calibration count.
    private static func recordedDays(windows: [(start: Int, end: Int)], endDay: Date) -> Int {
        let from = endDay.addingTimeInterval(-Double(SleepRegularity.windowDays) * 86_400).timeIntervalSince1970
        let days = windows.filter { Double($0.end) > from }.map {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.end)))
        }
        return Set(days).count
    }

    /// Minutes after midnight as a clock string in the app's clock format.
    private static func clockText(minutes: Double) -> String {
        let start = Calendar.current.startOfDay(for: Date())
        return AppClock.hourMinuteFormatter().string(from: start.addingTimeInterval(minutes * 60))
    }
}
