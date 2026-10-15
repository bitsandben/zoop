import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Explainer copy
//
// What each factor of the fitness age is and how it becomes years. The data-used, confidence and
// trend parts are filled per factor by `FitnessAgeFactorBuilder`; this file holds only the fixed text.

enum FitnessAgeExplanations {

    struct Copy {
        let whatItIs: LocalizedStringResource
        let method: MetricExplanation.Method
    }

    static func copy(_ factor: FitnessAgeFactor, bodyFatMeasured: Bool) -> Copy {
        switch factor {
        case .vo2max: return vo2max
        case .restingHR: return restingHR
        case .hrv: return hrv
        case .activity: return activity
        case .body: return bodyFatMeasured ? bodyFat : bmi
        case .sleep: return sleep
        }
    }

    private static let vo2max = Copy(
        whatItIs: LocalizedStringResource("zoop.fitnessage.explain.vo2",
            defaultValue: "How much oxygen your body can use at full effort. It is the strongest single marker of fitness and counts most."),
        method: .init(
            name: LocalizedStringResource("zoop.fitnessage.method.vo2", defaultValue: "Age at which a peer matches you"),
            summary: LocalizedStringResource("zoop.fitnessage.method.vo2.summary",
                defaultValue: "The age at which a typical person has your VO₂max, minus your age. Measured values use FRIEND norms, estimates the HUNT norms they were fitted on."),
            citation: "Nes et al., 2013; Kaminsky et al., 2015"))

    private static let restingHR = Copy(
        whatItIs: LocalizedStringResource("zoop.fitnessage.explain.rhr",
            defaultValue: "Your heart rate at rest over the last 30 days. A fitter heart needs fewer beats."),
        method: .init(
            name: LocalizedStringResource("zoop.fitnessage.method.rhr", defaultValue: "Distance from 65 bpm"),
            summary: LocalizedStringResource("zoop.fitnessage.method.rhr.summary",
                defaultValue: "Each bpm above or below 65 moves your age by about half a year, at the resting-heart-rate weight of the HUNT model."),
            citation: "Nes et al., 2011"))

    private static let hrv = Copy(
        whatItIs: LocalizedStringResource("zoop.fitnessage.explain.hrv",
            defaultValue: "The beat-to-beat variation of your heart at night. Higher values go with a fitter, calmer body."),
        method: .init(
            name: LocalizedStringResource("zoop.fitnessage.method.hrv", defaultValue: "Distance from the norm for your age"),
            summary: LocalizedStringResource("zoop.fitnessage.method.hrv.summary",
                defaultValue: "Your 30-day nightly RMSSD against the typical value for your age on a log scale; one spread is about 6 years.")))

    private static let activity = Copy(
        whatItIs: LocalizedStringResource("zoop.fitnessage.explain.activity",
            defaultValue: "How often and how hard you move in a typical week, on a scale from 0 to 15."),
        method: .init(
            name: LocalizedStringResource("zoop.fitnessage.method.activity", defaultValue: "HUNT activity index"),
            summary: LocalizedStringResource("zoop.fitnessage.method.activity.summary",
                defaultValue: "Active days per week times how hard those days were, read against a moderately active reference of 5; each point is about 0.76 years."),
            citation: "Nes et al., 2011"))

    private static let bodyFat = Copy(
        whatItIs: LocalizedStringResource("zoop.fitnessage.explain.bodyfat",
            defaultValue: "The share of your weight that is fat, from your scale or Apple Health."),
        method: .init(
            name: LocalizedStringResource("zoop.fitnessage.method.bodyfat", defaultValue: "Distance from a sex reference"),
            summary: LocalizedStringResource("zoop.fitnessage.method.bodyfat.summary",
                defaultValue: "Each point above or below 20 % (men) or 28 % (women) moves your age by about a third of a year.")))

    private static let bmi = Copy(
        whatItIs: LocalizedStringResource("zoop.fitnessage.explain.bmi",
            defaultValue: "Your weight against your height. It is a rough stand-in until a body-fat reading exists."),
        method: .init(
            name: LocalizedStringResource("zoop.fitnessage.method.bmi", defaultValue: "Distance from 18.5 to 25"),
            summary: LocalizedStringResource("zoop.fitnessage.method.bmi.summary",
                defaultValue: "Inside 18.5 to 25 adds nothing; each unit outside it adds about 0.8 years.")))

    private static let sleep = Copy(
        whatItIs: LocalizedStringResource("zoop.fitnessage.explain.sleep",
            defaultValue: "How similar your sleep length is from night to night. Steady sleep goes with better health."),
        method: .init(
            name: LocalizedStringResource("zoop.fitnessage.method.sleep", defaultValue: "Distance from 80 % regularity"),
            summary: LocalizedStringResource("zoop.fitnessage.method.sleep.summary",
                defaultValue: "Night-to-night regularity against 80 %; the factor is small and capped at 3 years either way.")))
}
