import Foundation
import StrandDesign

// MARK: - Meaning templates
//
// One sentence per (metric, verdict). The readout builder picks the sentence; nothing else on the
// screen words a verdict.

enum SleepMeanings {

    /// Sentence for a vital or stage placed against its range; nil verdicts fall back to "no value".
    static func meaning(_ id: MetricID, _ verdict: MetricVerdict) -> LocalizedStringResource {
        switch verdict {
        case .typical: return typical[id] ?? SleepStrings.noValueTonight
        case .above: return above[id] ?? SleepStrings.noValueTonight
        case .below: return below[id] ?? SleepStrings.noValueTonight
        case .score(let band): return score(band)
        case .load, .unavailable: return SleepStrings.noValueTonight
        }
    }

    static func score(_ band: ScoreBand) -> LocalizedStringResource {
        switch band {
        case .high: return LocalizedStringResource("zoop.sleep.meaning.score.high",
                                                   defaultValue: "You got the sleep your body asked for.")
        case .medium: return LocalizedStringResource("zoop.sleep.meaning.score.medium",
                                                     defaultValue: "Decent sleep, with room in duration or quality.")
        case .low: return LocalizedStringResource("zoop.sleep.meaning.score.low",
                                                  defaultValue: "Short or broken sleep, so take it easier today.")
        }
    }

    private static let typical: [MetricID: LocalizedStringResource] = [
        SleepMetricID.duration: LocalizedStringResource("zoop.sleep.meaning.duration.typical", defaultValue: "About as long as you usually sleep."),
        SleepMetricID.efficiency: LocalizedStringResource("zoop.sleep.meaning.efficiency.typical", defaultValue: "You spent your usual share of the night asleep."),
        SleepMetricID.deep: LocalizedStringResource("zoop.sleep.meaning.deep.typical", defaultValue: "Deep sleep in your usual range."),
        SleepMetricID.rem: LocalizedStringResource("zoop.sleep.meaning.rem.typical", defaultValue: "REM sleep in your usual range."),
        SleepMetricID.light: LocalizedStringResource("zoop.sleep.meaning.light.typical", defaultValue: "Light sleep in your usual range."),
        SleepMetricID.awake: LocalizedStringResource("zoop.sleep.meaning.awake.typical", defaultValue: "Your usual time awake during the night."),
        .hrv: LocalizedStringResource("zoop.sleep.meaning.hrv.typical", defaultValue: "Your nervous system recovered as usual overnight."),
        .restingHeartRate: LocalizedStringResource("zoop.sleep.meaning.rhr.typical", defaultValue: "Your heart rested as usual."),
        .respiratoryRate: LocalizedStringResource("zoop.sleep.meaning.resp.typical", defaultValue: "Breathing in your usual range."),
        .spo2: LocalizedStringResource("zoop.sleep.meaning.spo2.typical", defaultValue: "Blood oxygen in your usual range."),
        .skinTemperature: LocalizedStringResource("zoop.sleep.meaning.skin.typical", defaultValue: "Skin temperature close to your baseline."),
    ]

    private static let above: [MetricID: LocalizedStringResource] = [
        SleepMetricID.duration: LocalizedStringResource("zoop.sleep.meaning.duration.above", defaultValue: "Longer than you usually sleep."),
        SleepMetricID.efficiency: LocalizedStringResource("zoop.sleep.meaning.efficiency.above", defaultValue: "Less time awake in bed than usual."),
        SleepMetricID.deep: LocalizedStringResource("zoop.sleep.meaning.deep.above", defaultValue: "More deep sleep than usual, good for physical repair."),
        SleepMetricID.rem: LocalizedStringResource("zoop.sleep.meaning.rem.above", defaultValue: "More REM sleep than usual."),
        SleepMetricID.light: LocalizedStringResource("zoop.sleep.meaning.light.above", defaultValue: "More light sleep than usual."),
        SleepMetricID.awake: LocalizedStringResource("zoop.sleep.meaning.awake.above", defaultValue: "More time awake than usual."),
        .hrv: LocalizedStringResource("zoop.sleep.meaning.hrv.above", defaultValue: "Your nervous system recovered well overnight."),
        .restingHeartRate: LocalizedStringResource("zoop.sleep.meaning.rhr.above", defaultValue: "Higher than usual, so your body may still be working."),
        .respiratoryRate: LocalizedStringResource("zoop.sleep.meaning.resp.above", defaultValue: "Faster breathing than usual; watch it if it lasts."),
        .spo2: LocalizedStringResource("zoop.sleep.meaning.spo2.above", defaultValue: "Higher blood oxygen than usual."),
        .skinTemperature: LocalizedStringResource("zoop.sleep.meaning.skin.above", defaultValue: "Warmer than usual; illness or your cycle can do this."),
    ]

    private static let below: [MetricID: LocalizedStringResource] = [
        SleepMetricID.duration: LocalizedStringResource("zoop.sleep.meaning.duration.below", defaultValue: "Shorter than you usually sleep."),
        SleepMetricID.efficiency: LocalizedStringResource("zoop.sleep.meaning.efficiency.below", defaultValue: "More time awake in bed than usual."),
        SleepMetricID.deep: LocalizedStringResource("zoop.sleep.meaning.deep.below", defaultValue: "Less deep sleep than usual."),
        SleepMetricID.rem: LocalizedStringResource("zoop.sleep.meaning.rem.below", defaultValue: "Less REM sleep than usual."),
        SleepMetricID.light: LocalizedStringResource("zoop.sleep.meaning.light.below", defaultValue: "Less light sleep than usual."),
        SleepMetricID.awake: LocalizedStringResource("zoop.sleep.meaning.awake.below", defaultValue: "Less time awake than usual."),
        .hrv: LocalizedStringResource("zoop.sleep.meaning.hrv.below", defaultValue: "Lower than usual; stress, alcohol or illness can do this."),
        .restingHeartRate: LocalizedStringResource("zoop.sleep.meaning.rhr.below", defaultValue: "Lower than usual, a sign of good recovery."),
        .respiratoryRate: LocalizedStringResource("zoop.sleep.meaning.resp.below", defaultValue: "Slower breathing than usual."),
        .spo2: LocalizedStringResource("zoop.sleep.meaning.spo2.below", defaultValue: "Lower blood oxygen than usual; check the strap fit."),
        .skinTemperature: LocalizedStringResource("zoop.sleep.meaning.skin.below", defaultValue: "Cooler than usual."),
    ]
}

/// Sleep-specific metric ids. Stable: they double as explainer routes.
enum SleepMetricID {
    static let duration = MetricID.sleepDuration
    static let efficiency: MetricID = "sleep_efficiency"
    static let deep: MetricID = "sleep_stage_deep"
    static let rem: MetricID = "sleep_stage_rem"
    static let light: MetricID = "sleep_stage_light"
    static let awake: MetricID = "sleep_stage_awake"
    static let debt: MetricID = "sleep_debt"
    static let regularity: MetricID = "sleep_regularity"
}
