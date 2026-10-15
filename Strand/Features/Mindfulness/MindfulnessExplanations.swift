import Foundation
import StrandDesign

// MARK: - Mindfulness explainers
//
// What each number is, how it is measured and on how much data, for the explainer sheet behind every
// number in the section.

enum MindfulnessExplanations {

    private static func res(_ key: StaticString, _ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: value, bundle: .main)
    }

    static func minutes(weeks: Int) -> MetricExplanation {
        MetricExplanation(
            whatItIs: res("zoop.mindful.explain.minutes.what",
                          "Minutes of yoga, meditation, breathing, pilates, stretching and tai chi in the last 7 days."),
            method: .init(name: res("zoop.mindful.explain.minutes.method", "Rolling 7-day total"),
                          summary: res("zoop.mindful.explain.minutes.summary",
                                       "Overlapping sessions from the app, workouts and Apple Health count once; your range is the middle half of your earlier weeks.")),
            dataUsed: .init(count: .days(weeks * 7)))
    }

    static func days(weeks: Int) -> MetricExplanation {
        MetricExplanation(
            whatItIs: res("zoop.mindful.explain.days.what", "Days in the last 7 with at least one session of a minute or more."),
            method: .init(name: res("zoop.mindful.explain.days.method", "Practice days and streak"),
                          summary: res("zoop.mindful.explain.days.summary",
                                       "The streak counts days in a row ending today, or yesterday if you have not practised yet today.")),
            dataUsed: .init(count: .days(weeks * 7)))
    }

    static func hrDrop(sessions: Int, window: DateInterval) -> MetricExplanation {
        MetricExplanation(
            whatItIs: res("zoop.mindful.explain.hrDrop.what",
                          "How far your heart rate falls during practice: the relaxation response."),
            method: .init(name: res("zoop.mindful.explain.hrDrop.method", "Before vs settled"),
                          summary: res("zoop.mindful.explain.hrDrop.summary",
                                       "Mean HR in the second half of each session against the 10 minutes before it (or its first 3 minutes); a drop under 1.5 bpm counts as no clear change.")),
            dataUsed: .init(count: .samples(sessions), window: window),
            confidenceReason: res("zoop.mindful.explain.observational",
                                  "Observed in your own data, not a controlled study; posture and movement also change heart rate."))
    }

    static func hrvChange(sessions: Int, window: DateInterval) -> MetricExplanation {
        MetricExplanation(
            whatItIs: res("zoop.mindful.explain.hrv.what", "How your heart-rate variability (RMSSD) changes during practice."),
            method: .init(name: res("zoop.mindful.explain.hrv.method", "RMSSD before vs settled"),
                          summary: res("zoop.mindful.explain.hrv.summary",
                                       "Cleaned beat-to-beat intervals from the strap, same windows as the heart-rate drop; under 5 % counts as no clear change.")),
            dataUsed: .init(count: .samples(sessions), window: window),
            confidenceReason: res("zoop.mindful.explain.hrv.reason",
                                  "Slow breathing itself raises RMSSD, so part of the rise is the breathing, not only calm."))
    }

    static func stress(sessions: Int, window: DateInterval) -> MetricExplanation {
        MetricExplanation(
            whatItIs: res("zoop.mindful.explain.stress.what",
                          "The change in your stress level (0 to 3) from the hours before a session to the hours after it."),
            method: .init(name: res("zoop.mindful.explain.stress.method", "Hourly stress, 2 h each side"),
                          summary: res("zoop.mindful.explain.stress.summary",
                                       "Uses the day's hourly stress read; only whole hours fully before or after the session count, so short gaps are skipped.")),
            dataUsed: .init(count: .samples(sessions), window: window),
            confidenceReason: res("zoop.mindful.explain.observational",
                                  "Observed in your own data, not a controlled study; posture and movement also change heart rate."))
    }

    static func contrast(id: MetricID, with: Int, without: Int, window: DateInterval) -> MetricExplanation {
        let what = id == MindfulMetricID.rhrContrast
            ? res("zoop.mindful.explain.rhr.what", "Mean resting heart rate in nights after practice days; the delta is the gap to other nights.")
            : res("zoop.mindful.explain.hrvNight.what", "Mean night HRV after practice days; the delta is the gap to other nights.")
        return MetricExplanation(
            whatItIs: what,
            method: .init(name: res("zoop.mindful.explain.contrast.method", "Practice nights vs other nights"),
                          summary: res("zoop.mindful.explain.contrast.summary",
                                       "Last 60 days; a difference counts only with 5+ nights per group and a gap over twice its standard error.")),
            dataUsed: .init(count: .nights(with + without), window: window),
            confidenceReason: res("zoop.mindful.explain.contrast.reason",
                                  "Days you practise may differ in other ways too, so this shows a pattern, not a cause."))
    }
}
