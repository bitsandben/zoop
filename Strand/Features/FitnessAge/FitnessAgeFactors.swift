#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Factor rows as metric anatomy
//
// Each factor of the fitness age becomes a `MetricReadout` (value, the range it is scored against,
// verdict, one-sentence meaning) plus the years it adds or removes and an explainer. The screen only
// renders these; it never formats a number or picks a verdict word itself.

typealias FitnessSeries = [(day: String, value: Double)]

struct FitnessFactorItem: Identifiable {
    let factor: FitnessAgeFactor
    let readout: MetricReadout
    let explanation: MetricExplanation
    /// Weighted years this factor adds (positive = older) to the stored fitness age.
    let years: Double
    /// Recent daily signal behind the factor, for the sparkline and the trend word.
    let spark: FitnessSeries
    let trend: FitnessTrend

    var id: FitnessAgeFactor { factor }
}

enum FitnessAgeFactorBuilder {

    struct Context {
        let age: Int
        let sex: String
        let snapshot: FitnessAgeSnapshot
        /// 7-day rolling means of each factor's daily signal.
        let series: [FitnessAgeFactor: FitnessSeries]
        let now: Date
    }

    static func items(_ ctx: Context) -> [FitnessFactorItem] {
        FitnessAgeFactor.allCases.compactMap { item($0, ctx) }
    }

    private static func item(_ factor: FitnessAgeFactor, _ ctx: Context) -> FitnessFactorItem? {
        guard let years = ctx.snapshot.contributions[factor] else { return nil }
        let spec = spec(factor, ctx)
        guard let raw = ctx.snapshot.inputs[spec.inputKey] else { return nil }
        let value = raw * spec.scale
        let spark = ctx.series[factor] ?? []

        let readout = MetricReadout(
            id: MetricID(rawValue: "fitness_age_" + factor.rawValue),
            label: spec.label, value: value, unit: spec.unit,
            typicalRange: spec.range, rangeIsPersonal: false,
            verdict: .vital(value, typicalRange: spec.range),
            meaning: meaning(years: years), tint: .neutral,
            polarity: factor == .restingHR || factor == .body ? .lowerIsBetter : .higherIsBetter)

        let copy = FitnessAgeExplanations.copy(factor, bodyFatMeasured: ctx.snapshot.inputs[FitnessAgeKeys.bodyFat] != nil)
        let explanation = MetricExplanation(
            whatItIs: copy.whatItIs, method: copy.method,
            dataUsed: .init(count: .days(30), window: window(ctx.now),
                            source: factor == .vo2max && ctx.snapshot.vo2IsMeasured ? "Apple Health" : nil),
            confidenceReason: confidence(factor, ctx),
            trend: spec.trendMatchesValue ? trendPoints(spark) : [])

        return FitnessFactorItem(
            factor: factor, readout: readout, explanation: explanation, years: years, spark: spark,
            trend: FitnessTrend.of(spark, lowerIsBetter: factor == .restingHR || factor == .body))
    }

    // MARK: Per-factor specification

    private struct Spec {
        let label: LocalizedStringResource
        let inputKey: String
        let unit: MetricUnit
        /// Stored values are fractions for sleep regularity; the readout shows a percent.
        var scale = 1.0
        /// The range the engine scores this factor against: its reference or the age norm.
        let range: ClosedRange<Double>
        /// Whether the daily signal in the sparkline is the same quantity as the readout's value, so
        /// the explainer may plot it against the range.
        var trendMatchesValue = false
    }

    private static func spec(_ factor: FitnessAgeFactor, _ ctx: Context) -> Spec {
        let age = Double(ctx.age)
        let female = ctx.sex.lowercased() == "female"
        let inputs = ctx.snapshot.inputs
        switch factor {
        case .vo2max:
            // Peers within five years of you: the norm at age+5 is the low edge, at age-5 the high one.
            let source: FitnessVO2Source = ctx.snapshot.vo2IsMeasured ? .measured : .nesEstimate
            let lo = FitnessAgeEngine.vo2Norm(age: age + 5, sex: ctx.sex, source: source)
            let hi = FitnessAgeEngine.vo2Norm(age: max(18, age - 5), sex: ctx.sex, source: source)
            return Spec(label: ctx.snapshot.vo2IsMeasured ? FitnessAgeStrings.labelVO2 : FitnessAgeStrings.labelVO2Estimated,
                        inputKey: factor.inputKey, unit: .vo2max, range: lo...max(lo, hi), trendMatchesValue: true)
        case .restingHR:
            let ref = FitnessAgeEngine.restingHRReference
            return Spec(label: FitnessAgeStrings.labelRHR, inputKey: factor.inputKey, unit: .beatsPerMinute,
                        range: (ref - 10)...(ref + 10), trendMatchesValue: true)
        case .hrv:
            // One log-scale spread (0.45) around the age norm, the spread the engine scores in.
            let norm = VitalityEngine.rmssdNorm(forAge: age)
            return Spec(label: FitnessAgeStrings.labelHRV, inputKey: factor.inputKey, unit: .milliseconds,
                        range: (norm * exp(-0.45))...(norm * exp(0.45)), trendMatchesValue: true)
        case .activity:
            let ref = FitnessAgeEngine.paiReference
            return Spec(label: FitnessAgeStrings.labelActivity, inputKey: factor.inputKey,
                        unit: .score(fractionDigits: 1), range: (ref - 2)...(ref + 2))
        case .body:
            if inputs[FitnessAgeKeys.bodyFat] != nil {
                let ref = female ? 28.0 : 20.0
                return Spec(label: FitnessAgeStrings.labelBodyFat, inputKey: FitnessAgeKeys.bodyFat,
                            unit: .percent, range: (ref - 5)...(ref + 5), trendMatchesValue: true)
            }
            return Spec(label: FitnessAgeStrings.labelBMI, inputKey: FitnessAgeKeys.bmi,
                        unit: .score(fractionDigits: 1), range: 18.5...25)
        case .sleep:
            return Spec(label: FitnessAgeStrings.labelSleep, inputKey: factor.inputKey, unit: .percent,
                        scale: 100, range: 70...90)
        }
    }

    // MARK: Text

    /// One sentence from the sign of the years, so the verdict word and the years can't disagree.
    private static func meaning(years: Double) -> LocalizedStringResource {
        let n = fitnessOneDecimal(abs(years))
        if years < -0.05 { return FitnessAgeStrings.removes(n) }
        if years > 0.05 { return FitnessAgeStrings.adds(n) }
        return FitnessAgeStrings.neutral
    }

    private static func confidence(_ factor: FitnessAgeFactor, _ ctx: Context) -> LocalizedStringResource {
        if factor == .vo2max, !ctx.snapshot.vo2IsMeasured {
            let female = ctx.sex.lowercased() == "female"
            return FitnessAgeStrings.confidenceEstimate(
                fitnessOneDecimal(female ? FitnessAgeEngine.seeWomen : FitnessAgeEngine.seeMen))
        }
        return FitnessAgeStrings.confidenceWeekly
    }

    private static func window(_ now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-30 * 86_400), end: now)
    }

    /// The last 30 days of a factor's signal as explainer trend points.
    static func trendPoints(_ series: FitnessSeries) -> [MetricExplanation.TrendPoint] {
        series.suffix(30).compactMap { p in
            fitnessDayDate(p.day).map { MetricExplanation.TrendPoint(date: $0, value: p.value) }
        }
    }
}
#endif
