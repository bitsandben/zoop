import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - The three ring readouts (Recovery, Sleep, Strain) and the synthesis sentence
//
// Pure builders: the model hands in what it loaded, these return `MetricReadout`s. Each ring reads the
// same resolver as its detail screen, so the ring and the screen it opens cannot show two numbers.

/// What Recovery can honestly say for the selected day.
enum RecoveryDisplay: Equatable {
    /// The day scored its own Recovery.
    case scored(pct: Double)
    /// Today is unscored; this is the last scored night's value, from `day` (#543).
    case carried(pct: Double, day: String)
    /// The HRV baseline is still forming: `nights` of `Baselines.minNightsSeed` are banked.
    case calibrating(nights: Int)
    case noData

    var pct: Double? {
        switch self {
        case .scored(let p), .carried(let p, _): return p
        case .calibrating, .noData: return nil
        }
    }

    /// Calibration beats the carry: mid-calibration there is no trustworthy prior score to stand in.
    static func resolve(todayRecovery: Double?, priorScored: DailyMetric?, calibrationNights: Int?) -> RecoveryDisplay {
        if let pct = todayRecovery { return .scored(pct: pct) }
        if let n = calibrationNights { return .calibrating(nights: n) }
        guard let prior = priorScored, let pct = prior.recovery else { return .noData }
        return .carried(pct: pct, day: prior.day)
    }
}

enum TodayRings {

    // MARK: Recovery

    /// `hrvBaseline` is the baseline the score was computed against (`Repository.chargeBaselines`), so
    /// the confidence comes from `RecoveryScorer.assessment`, the one Recovery resolver.
    static func recovery(_ display: RecoveryDisplay, hrvBaseline: BaselineState?) -> MetricReadout {
        switch display {
        case .scored(let pct):
            let assessment = RecoveryScorer.assessment(score: pct, hrvBaseline: hrvBaseline)
            return recoveryReadout(pct, confidence: confidence(assessment.confidence))
        case .carried(let pct, let day):
            let since = TodayLogic.dayKeyParser.date(from: day) ?? Date()
            return recoveryReadout(pct, confidence: .stale(since: since))
        case .calibrating(let nights):
            let left = max(1, Baselines.minNightsSeed - nights)
            return MetricReadout(id: .recovery, label: TodayCopy.recovery, value: nil, unit: .percent,
                                 verdict: .unavailable(.calibrating(nightsLeft: left)),
                                 meaning: TodayCopy.recoveryCalibrating,
                                 confidence: .calibrating(nightsLeft: left), tint: .recovery)
        case .noData:
            return MetricReadout(id: .recovery, label: TodayCopy.recovery, value: nil, unit: .percent,
                                 verdict: .unavailable(.noData(since: nil)), meaning: TodayCopy.recoveryNoData,
                                 tint: .recovery)
        }
    }

    private static func recoveryReadout(_ pct: Double, confidence: MetricReadout.Confidence) -> MetricReadout {
        let band = ScoreBand(score: pct)
        return MetricReadout(id: .recovery, label: TodayCopy.recovery, value: pct, unit: .percent,
                             verdict: .score(band), meaning: TodayCopy.recoveryMeaning(band),
                             confidence: confidence, tint: .recovery)
    }

    // MARK: Sleep

    /// The night the Sleep screen leads with: the newest night on or before the selected day. A newer
    /// night than the selected day never applies; an older one on today is shown but dated (stale), so the
    /// ring and the Sleep screen show the same night instead of "no data" next to a score.
    struct SleepNight: Equatable {
        let wakeDay: String
        let score: Double?
    }

    static func sleep(_ night: SleepNight?, selectedDay: String, isToday: Bool) -> MetricReadout {
        guard let night, let score = night.score, night.wakeDay <= selectedDay,
              isToday || night.wakeDay == selectedDay else {
            return MetricReadout(id: .sleepScore, label: TodayCopy.sleep, value: nil, unit: .score,
                                 verdict: .unavailable(.noData(since: night.flatMap { TodayLogic.dayKeyParser.date(from: $0.wakeDay) })),
                                 meaning: TodayCopy.sleepNoData, tint: .sleep)
        }
        let band = ScoreBand(score: score)
        let confidence: MetricReadout.Confidence = night.wakeDay == selectedDay
            ? .solid
            : .stale(since: TodayLogic.dayKeyParser.date(from: night.wakeDay) ?? Date())
        return MetricReadout(id: .sleepScore, label: TodayCopy.sleep, value: score, unit: .score,
                             verdict: .score(band), meaning: TodayCopy.sleepMeaning(band),
                             confidence: confidence, tint: .sleep)
    }

    /// The Sleep screen's per-night score (`SleepView.performanceScore`): the imported figure for that
    /// wake day when an export carried one, else the Rest composite of that day's row.
    static func sleepScore(wakeDay: String, importedPct: Double?, row: DailyMetric?) -> Double? {
        if let importedPct { return importedPct }
        return row.flatMap { AnalyticsEngine.Rest.composite(daily: $0) }
    }

    // MARK: Strain

    /// Strain arrives on the stored 0–100 axis; `whoopScale` shows it on WHOOP's 0–21 axis instead.
    static func strain(_ stored: Double?, whoopScale: Bool, hrSamples: Int?) -> MetricReadout {
        let unit = MetricUnit.score(fractionDigits: whoopScale ? 1 : 0)
        guard let stored else {
            return MetricReadout(id: .strain, label: TodayCopy.strain, value: nil, unit: unit,
                                 verdict: .unavailable(.noData(since: nil)), meaning: TodayCopy.strainNoData,
                                 tint: .strain)
        }
        let band = loadBand(strain21: stored * strainScaleFactor)
        let confidence: MetricReadout.Confidence = hrSamples.map {
            ScoreConfidence.effort(strain: stored, hrSampleCount: $0) == .solid ? .solid : .building
        } ?? .solid
        return MetricReadout(id: .strain, label: TodayCopy.strain,
                             value: whoopScale ? stored * strainScaleFactor : stored, unit: unit,
                             verdict: .load(band), meaning: TodayCopy.strainMeaning(band),
                             confidence: confidence, tint: .strain)
    }

    /// The stored 0–100 strain on WHOOP's 0–21 axis (`UnitFormatter.effortScaleFactor`).
    static let strainScaleFactor = 0.21

    /// WHOOP's day-strain zones on the 0–21 axis: light below 10, moderate to 14, strenuous to 18, then
    /// all out. The same cut points `CoupledView.optimalStrainRange` targets.
    static func loadBand(strain21: Double) -> LoadBand {
        switch strain21 {
        case ..<10: return .restorative
        case ..<14: return .building
        case ..<18: return .demanding
        default: return .overreaching
        }
    }

    /// Today's target span on the 0–21 axis for a Recovery, as fractions of the ring.
    static func strainTarget(recovery: Double?) -> ClosedRange<Double>? {
        CoupledView.optimalStrainRange(recovery: recovery).map { Double($0.lowerBound) / 21 ... Double($0.upperBound) / 21 }
    }

    /// "Target 10–14" in the strain readout's own unit and locale.
    static func strainTargetCaption(recovery: Double?, whoopScale: Bool, locale: Locale) -> LocalizedStringResource? {
        guard let band = CoupledView.optimalStrainRange(recovery: recovery) else { return nil }
        let unit = MetricUnit.score(fractionDigits: 0)
        let scale = whoopScale ? 1 : 100.0 / 21
        return TodayCopy.strainTarget(unit.number(Double(band.lowerBound) * scale, locale: locale),
                                      unit.number(Double(band.upperBound) * scale, locale: locale))
    }

    // MARK: Synthesis

    /// One sentence under the rings, from Recovery alone (the rings already show the rest). Today only:
    /// a past day's plan is no longer actionable.
    static func synthesis(_ display: RecoveryDisplay, isToday: Bool) -> LocalizedStringResource? {
        guard isToday else { return nil }
        switch display {
        case .scored(let pct), .carried(let pct, _): return TodayCopy.synthesis(ScoreBand(score: pct))
        case .calibrating: return TodayCopy.synthesisCalibrating
        case .noData: return nil
        }
    }

    // MARK: Helpers

    static func confidence(_ c: ScoreConfidence) -> MetricReadout.Confidence {
        switch c {
        case .solid: return .solid
        case .building: return .building
        case .calibrating: return .calibrating(nightsLeft: 1)
        }
    }
}
