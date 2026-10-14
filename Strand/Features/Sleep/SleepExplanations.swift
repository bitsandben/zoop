import Foundation
import StrandDesign

// MARK: - Explainer copy
//
// What each Sleep metric is and how it is computed. The data-used, confidence and trend parts are
// filled per readout by `SleepReadouts`; this file holds only the fixed text.

enum SleepExplanations {

    struct Copy {
        let whatItIs: LocalizedStringResource
        let method: MetricExplanation.Method
    }

    static func copy(_ id: MetricID) -> Copy {
        switch id {
        case .sleepScore: return score
        case SleepMetricID.duration: return duration
        case SleepMetricID.efficiency: return efficiency
        case SleepMetricID.deep: return stage(LocalizedStringResource("zoop.sleep.explain.deep",
            defaultValue: "Deep, slow-wave sleep is when the body does most of its physical repair."))
        case SleepMetricID.rem: return stage(LocalizedStringResource("zoop.sleep.explain.rem",
            defaultValue: "REM sleep supports memory and mood, and grows longer towards morning."))
        case SleepMetricID.light: return stage(LocalizedStringResource("zoop.sleep.explain.light",
            defaultValue: "Light sleep links the other stages and fills about half of a night."))
        case SleepMetricID.awake: return stage(LocalizedStringResource("zoop.sleep.explain.awake",
            defaultValue: "Time awake between falling asleep and getting up."))
        case SleepMetricID.debt: return debt
        case SleepMetricID.regularity: return regularity
        case .hrv: return hrv
        case .restingHeartRate: return restingHR
        case .respiratoryRate: return respiratory
        case .spo2: return spo2
        default: return skin
        }
    }

    private static let score = Copy(
        whatItIs: LocalizedStringResource("zoop.sleep.explain.score",
            defaultValue: "How well the night met your sleep need, from 0 to 100, weighing duration, efficiency, deep and REM sleep, and timing."),
        method: .init(name: LocalizedStringResource("zoop.sleep.method.score", defaultValue: "Sleep composite"),
                      summary: LocalizedStringResource("zoop.sleep.method.score.summary",
            defaultValue: "Time asleep against need 45 %, efficiency 20 %, deep and REM share 20 %, timing 15 %.")))

    private static let duration = Copy(
        whatItIs: LocalizedStringResource("zoop.sleep.explain.duration",
            defaultValue: "Time actually asleep, without the time you lay awake."),
        method: .init(name: LocalizedStringResource("zoop.sleep.method.duration", defaultValue: "Stage totals"),
                      summary: LocalizedStringResource("zoop.sleep.method.duration.summary",
            defaultValue: "Light, deep and REM minutes added up over the main sleep and the fragments bridged into it.")))

    private static let efficiency = Copy(
        whatItIs: LocalizedStringResource("zoop.sleep.explain.efficiency",
            defaultValue: "The share of your time in bed that you spent asleep."),
        method: .init(name: LocalizedStringResource("zoop.sleep.method.efficiency", defaultValue: "Asleep ÷ time in bed"),
                      summary: LocalizedStringResource("zoop.sleep.method.efficiency.summary",
            defaultValue: "Sleep minutes divided by the minutes from falling asleep to waking up.")))

    private static func stage(_ what: LocalizedStringResource) -> Copy {
        Copy(whatItIs: what,
             method: .init(name: LocalizedStringResource("zoop.sleep.method.stages", defaultValue: "Heart-rate and movement staging"),
                           summary: LocalizedStringResource("zoop.sleep.method.stages.summary",
            defaultValue: "Each 30 seconds is estimated from heart rate, HRV and movement; agreement with a sleep lab is moderate."),
                           citation: "Cohen's κ 0.35, 44-subject benchmark"))
    }

    private static let debt = Copy(
        whatItIs: LocalizedStringResource("zoop.sleep.explain.debt",
            defaultValue: "Sleep missed against your need over the last 14 nights, with older nights counting less."),
        method: .init(name: LocalizedStringResource("zoop.sleep.method.debt", defaultValue: "Weighted sleep ledger"),
                      summary: LocalizedStringResource("zoop.sleep.method.debt.summary",
            defaultValue: "Each night carries 55 % of the shortfall forward, and under ten minutes clears to zero."),
                      citation: "Van Dongen et al., 2003"))

    private static let regularity = Copy(
        whatItIs: LocalizedStringResource("zoop.sleep.explain.regularity",
            defaultValue: "How alike your sleep and wake times are from one day to the next, from 0 to 100."),
        method: .init(name: LocalizedStringResource("zoop.sleep.method.regularity", defaultValue: "Sleep Regularity Index"),
                      summary: LocalizedStringResource("zoop.sleep.method.regularity.summary",
            defaultValue: "The chance of being in the same state, asleep or awake, 24 hours apart over the last 14 days."),
                      citation: "Phillips et al., 2017"))

    private static let hrv = Copy(
        whatItIs: LocalizedStringResource("zoop.sleep.explain.hrv",
            defaultValue: "The variation between heartbeats during sleep; higher usually means better recovery."),
        method: .init(name: LocalizedStringResource("zoop.sleep.method.hrv", defaultValue: "Nightly RMSSD"),
                      summary: LocalizedStringResource("zoop.sleep.method.hrv.summary",
            defaultValue: "Root mean square of successive beat-to-beat differences over clean sleep windows."),
                      citation: "Task Force ESC/NASPE, 1996"))

    private static let restingHR = Copy(
        whatItIs: LocalizedStringResource("zoop.sleep.explain.rhr",
            defaultValue: "Your lowest steady heart rate while asleep."),
        method: .init(name: LocalizedStringResource("zoop.sleep.method.rhr", defaultValue: "Sleeping heart-rate floor"),
                      summary: LocalizedStringResource("zoop.sleep.method.rhr.summary",
            defaultValue: "The lowest sustained heart rate across the main sleep.")))

    private static let respiratory = Copy(
        whatItIs: LocalizedStringResource("zoop.sleep.explain.resp",
            defaultValue: "Breaths per minute while asleep."),
        method: .init(name: LocalizedStringResource("zoop.sleep.method.resp", defaultValue: "Respiratory sinus arrhythmia"),
                      summary: LocalizedStringResource("zoop.sleep.method.resp.summary",
            defaultValue: "Breathing rate read from the rhythm it leaves in the beat-to-beat intervals.")))

    private static let spo2 = Copy(
        whatItIs: LocalizedStringResource("zoop.sleep.explain.spo2",
            defaultValue: "Average oxygen saturation of your blood during sleep."),
        method: .init(name: LocalizedStringResource("zoop.sleep.method.spo2", defaultValue: "Red and infrared light ratio"),
                      summary: LocalizedStringResource("zoop.sleep.method.spo2.summary",
            defaultValue: "The average of the strap's red and infrared light readings while you slept.")))

    private static let skin = Copy(
        whatItIs: LocalizedStringResource("zoop.sleep.explain.skin",
            defaultValue: "How far your skin temperature sat from your own baseline during sleep."),
        method: .init(name: LocalizedStringResource("zoop.sleep.method.skin", defaultValue: "Nightly deviation"),
                      summary: LocalizedStringResource("zoop.sleep.method.skin.summary",
            defaultValue: "Worn, in-bed skin temperature compared with your rolling baseline.")))

    // Score contributors
    static let contributorDuration = LocalizedStringResource("zoop.sleep.contrib.duration", defaultValue: "Time asleep against need")
    static let contributorEfficiency = LocalizedStringResource("zoop.sleep.contrib.efficiency", defaultValue: "Efficiency")
    static let contributorRestorative = LocalizedStringResource("zoop.sleep.contrib.restorative", defaultValue: "Deep and REM share")
}
