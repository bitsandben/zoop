import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Recovery copy (zoop.recovery.* catalogue entries)
//
// Every sentence is a template keyed by (metric, verdict), never free text, so the same state reads the
// same everywhere. Keys live in Strand/Resources/Localizable.xcstrings; the English text is the default
// value that previews and tests fall back to.

enum RecoveryStrings {

    private static func r(_ key: StaticString, _ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: value, bundle: .main)
    }

    // Hero
    static let title = r("zoop.recovery.title", "Recovery")
    static let heroLabelLastNight = r("zoop.recovery.hero.label.lastNight", "Last night")
    static let heroLabelLastReading = r("zoop.recovery.hero.label.lastReading", "Last reading")

    static func heroMeaning(_ band: ScoreBand) -> LocalizedStringResource {
        switch band {
        case .high: return r("zoop.recovery.hero.meaning.high", "You are ready for a demanding day.")
        case .medium: return r("zoop.recovery.hero.meaning.medium", "Your body is coping. Keep the day balanced.")
        case .low: return r("zoop.recovery.hero.meaning.low", "Your body needs a calmer day.")
        }
    }
    static let heroMeaningCalibrating = r("zoop.recovery.hero.meaning.calibrating",
        "Your recovery needs a few more nights to learn what is normal for you.")
    static let heroMeaningMissing = r("zoop.recovery.hero.meaning.missing",
        "Last night lacked the HRV or resting heart rate that Recovery needs.")

    // Contributors
    static let contributorsTitle = r("zoop.recovery.contributors.title", "What shaped it")
    static let contributorsNote = r("zoop.recovery.contributors.note", "Sorted by impact on your score.")
    static let effectRaises = r("zoop.recovery.effect.raises", "Raises your recovery")
    static let effectLowers = r("zoop.recovery.effect.lowers", "Lowers your recovery")
    static let effectNeutral = r("zoop.recovery.effect.neutral", "No effect")

    static func label(_ kind: RecoveryContributor.Kind) -> LocalizedStringResource {
        switch kind {
        case .hrv: return r("zoop.recovery.label.hrv", "HRV")
        case .restingHR: return r("zoop.recovery.label.rhr", "Resting heart rate")
        case .sleep: return r("zoop.recovery.label.sleep", "Sleep")
        case .respiration: return r("zoop.recovery.label.resp", "Respiratory rate")
        case .skinTemperature: return r("zoop.recovery.label.skin", "Skin temperature")
        }
    }

    /// One sentence per (metric, verdict). Sleep is judged against the sleep needed, so its words differ.
    static func meaning(_ kind: RecoveryContributor.Kind, _ verdict: MetricVerdict) -> LocalizedStringResource {
        switch (kind, verdict) {
        case (.hrv, .above): return r("zoop.recovery.meaning.hrv.above", "Your nervous system recovered well overnight.")
        case (.hrv, .below): return r("zoop.recovery.meaning.hrv.below", "Your HRV was lower than usual.")
        case (.hrv, _): return r("zoop.recovery.meaning.hrv.typical", "Your HRV was in its usual range.")
        case (.restingHR, .above): return r("zoop.recovery.meaning.rhr.above", "Your heart rate stayed higher than usual overnight.")
        case (.restingHR, .below): return r("zoop.recovery.meaning.rhr.below", "Your heart rate settled lower than usual.")
        case (.restingHR, _): return r("zoop.recovery.meaning.rhr.typical", "Your heart rate settled as low as usual.")
        case (.respiration, .above): return r("zoop.recovery.meaning.resp.above", "You breathed faster than usual overnight.")
        case (.respiration, .below): return r("zoop.recovery.meaning.resp.below", "You breathed slower than usual overnight.")
        case (.respiration, _): return r("zoop.recovery.meaning.resp.typical", "Your breathing was as steady as usual.")
        case (.skinTemperature, .above): return r("zoop.recovery.meaning.skin.above", "Your skin ran warmer than your baseline.")
        case (.skinTemperature, .below): return r("zoop.recovery.meaning.skin.below", "Your skin ran cooler than your baseline.")
        case (.skinTemperature, _): return r("zoop.recovery.meaning.skin.typical", "Your skin temperature was in its usual range.")
        case (.sleep, .above): return r("zoop.recovery.meaning.sleep.above", "You slept more than you need.")
        case (.sleep, .below): return r("zoop.recovery.meaning.sleep.below", "You slept less than you need.")
        case (.sleep, _): return r("zoop.recovery.meaning.sleep.typical", "You slept about as much as you need.")
        }
    }

    // Trend
    static let trendTitle = r("zoop.recovery.trend.title", "Trend")
    static let trend30 = r("zoop.recovery.trend.30", "30 days")
    static let trend90 = r("zoop.recovery.trend.90", "90 days")
    static let trendEmpty = r("zoop.recovery.trend.empty", "Your recovery scores will appear here after a few nights.")
    static let trendChartLabel = r("zoop.recovery.trend.chart", "Recovery per day")
    static func trendAverage(_ value: String) -> LocalizedStringResource {
        r("zoop.recovery.trend.average", "Average \(value)")
    }

    // Forecast
    static let forecastTitle = r("zoop.recovery.forecast.title", "Tomorrow")
    static func forecastCaption(sleep: String) -> LocalizedStringResource {
        r("zoop.recovery.forecast.caption", "Estimate if you sleep about \(sleep). Not a measurement.")
    }

    // Calibration timeline
    static let timelineTitle = r("zoop.recovery.timeline.title", "Learning your normal")
    static let stepScore = r("zoop.recovery.timeline.score", "First Recovery score")
    static let stepPersonal = r("zoop.recovery.timeline.personal", "Personal range")
    static func stepAfter(_ nights: Int) -> LocalizedStringResource {
        r("zoop.recovery.timeline.after", "After \(nights) nights")
    }
    static func stepProgress(_ done: Int, of total: Int) -> LocalizedStringResource {
        r("zoop.recovery.timeline.progress", "\(done) of \(total) nights")
    }

    // Personalisation
    static let personalTitle = r("zoop.recovery.personal.title", "Personalisation")
    static let personalOff = r("zoop.recovery.personal.off",
        "Answer a short check-in each morning and Zoop tunes Recovery to how you feel.")
    static func personalCollecting(_ done: Int, of total: Int) -> LocalizedStringResource {
        r("zoop.recovery.personal.collecting", "\(done) of \(total) check-ins until the first adjustment.")
    }
    static let personalNoShift = r("zoop.recovery.personal.noShift", "Your check-ins match the standard weighting.")
    static func personalHigher(_ term: String, _ percent: Int) -> LocalizedStringResource {
        r("zoop.recovery.personal.higher", "Your check-ins weight \(term) \(percent)% higher.")
    }
    static func personalLower(_ term: String, _ percent: Int) -> LocalizedStringResource {
        r("zoop.recovery.personal.lower", "Your check-ins weight \(term) \(percent)% lower.")
    }
    static func personalToday(_ feeling: String) -> LocalizedStringResource {
        r("zoop.recovery.personal.today", "Today's check-in: \(feeling)")
    }

    // Explainer
    static let heroWhatItIs = r("zoop.recovery.explain.what",
        "Recovery shows how ready your body is for the day, from 0 to 100. It compares last night with your own normal.")
    static let heroMethodName = r("zoop.recovery.explain.method.name", "Weighted comparison with your baseline")
    static let heroMethodSummary = r("zoop.recovery.explain.method.summary",
        "HRV, resting heart rate, sleep, breathing and skin temperature are compared with your own recent nights and combined.")
    static func confidenceSolid(_ nights: Int) -> LocalizedStringResource {
        r("zoop.recovery.explain.confidence.solid", "Built from \(nights) nights of your own data.")
    }
    static func confidenceBuilding(_ nights: Int, of total: Int) -> LocalizedStringResource {
        r("zoop.recovery.explain.confidence.building", "Still settling: \(nights) of \(total) nights so far.")
    }
    static func confidenceCalibrating(_ nights: Int) -> LocalizedStringResource {
        r("zoop.recovery.explain.confidence.calibrating", "Zoop needs \(nights) nights of data for a first score.")
    }
    static let contributorMethodName = r("zoop.recovery.explain.contributor.name", "Comparison with your range")
    static func contributorMethodSummary(share: Int) -> LocalizedStringResource {
        r("zoop.recovery.explain.contributor.summary",
          "Your value is compared with your own typical range. It carries \(share)% of the score.")
    }

    static func whatItIs(_ kind: RecoveryContributor.Kind) -> LocalizedStringResource {
        switch kind {
        case .hrv: return r("zoop.recovery.explain.hrv",
            "HRV is the variation between heartbeats overnight. Higher than usual points to good recovery.")
        case .restingHR: return r("zoop.recovery.explain.rhr",
            "Resting heart rate is how low your heart rate settles during sleep. Lower than usual points to good recovery.")
        case .sleep: return r("zoop.recovery.explain.sleep", "Sleep compares the time you slept with the time you need.")
        case .respiration: return r("zoop.recovery.explain.resp",
            "Respiratory rate is how many breaths you take per minute asleep. A rise can signal strain or illness.")
        case .skinTemperature: return r("zoop.recovery.explain.skin",
            "Skin temperature is shown as the difference from your own baseline. Drifts in either direction lower Recovery.")
        }
    }
}
