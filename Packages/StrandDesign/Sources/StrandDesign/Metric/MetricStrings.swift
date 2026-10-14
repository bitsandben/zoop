import Foundation

// MARK: - Metric copy (zoop.metric.* catalogue entries)
//
// These keys live in the app's catalogue (Strand/Resources/Localizable.xcstrings), not in the
// package's, so every metric string is translated in the one place the screens' copy already is.
// `bundle: .main` resolves them against the running app; package tests and previews fall back to
// the English default value.

enum MetricStrings {
    // Verdicts
    static let verdictTypical = LocalizedStringResource("zoop.metric.verdict.typical", defaultValue: "Typical", bundle: .main)
    static let verdictAbove = LocalizedStringResource("zoop.metric.verdict.above", defaultValue: "Above your range", bundle: .main)
    static let verdictBelow = LocalizedStringResource("zoop.metric.verdict.below", defaultValue: "Below your range", bundle: .main)
    static let scoreHigh = LocalizedStringResource("zoop.metric.verdict.score.high", defaultValue: "High", bundle: .main)
    static let scoreMedium = LocalizedStringResource("zoop.metric.verdict.score.medium", defaultValue: "Medium", bundle: .main)
    static let scoreLow = LocalizedStringResource("zoop.metric.verdict.score.low", defaultValue: "Low", bundle: .main)
    static let loadRestorative = LocalizedStringResource("zoop.metric.verdict.load.restorative", defaultValue: "Restorative", bundle: .main)
    static let loadBuilding = LocalizedStringResource("zoop.metric.verdict.load.building", defaultValue: "Building", bundle: .main)
    static let loadDemanding = LocalizedStringResource("zoop.metric.verdict.load.demanding", defaultValue: "Demanding", bundle: .main)
    static let loadOverreaching = LocalizedStringResource("zoop.metric.verdict.load.overreaching", defaultValue: "Overreaching", bundle: .main)

    // Data state
    static let noDataYet = LocalizedStringResource("zoop.metric.state.noData", defaultValue: "No data yet", bundle: .main)
    static func nightsLeft(_ nights: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.state.nightsLeft", defaultValue: "\(nights) more nights", bundle: .main)
    }
    static func noDataSince(_ date: Date) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.state.noDataSince",
                                defaultValue: "No data since \(date, format: .dateTime.day().month(.abbreviated))", bundle: .main)
    }

    // Confidence
    static let calibrated = LocalizedStringResource("zoop.metric.confidence.solid", defaultValue: "Calibrated", bundle: .main)
    static let calibrating = LocalizedStringResource("zoop.metric.confidence.calibrating", defaultValue: "Calibrating", bundle: .main)
    static let provisional = LocalizedStringResource("zoop.metric.confidence.building", defaultValue: "Provisional", bundle: .main)
    static func asOf(_ date: Date) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.confidence.stale",
                                defaultValue: "As of \(date, format: .dateTime.day().month(.abbreviated))", bundle: .main)
    }

    // Range and delta
    static func populationRange(nightsLeft: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.range.population",
                                defaultValue: "Population range, personal range in \(nightsLeft) nights", bundle: .main)
    }
    static func yourRange(_ range: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.range.personal", defaultValue: "Your range \(range)", bundle: .main)
    }
    static func populationRangeValue(_ range: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.range.populationValue", defaultValue: "Population range \(range)", bundle: .main)
    }
    static func vsTypical(_ delta: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.delta.vsTypical", defaultValue: "\(delta) vs. typical", bundle: .main)
    }
    static func vsYesterday(_ delta: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.delta.vsYesterday", defaultValue: "\(delta) vs. yesterday", bundle: .main)
    }

    static let change = LocalizedStringResource("zoop.metric.a11y.change", defaultValue: "Change", bundle: .main)
    static let range = LocalizedStringResource("zoop.metric.a11y.range", defaultValue: "Range", bundle: .main)

    // Units: short symbol where it is translated, spoken form for VoiceOver
    static func millisecondsSpoken(_ v: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.unit.ms.spoken", defaultValue: "\(v) milliseconds", bundle: .main)
    }
    static func celsiusSpoken(_ v: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.unit.celsius.spoken", defaultValue: "\(v) degrees Celsius", bundle: .main)
    }
    static func kilogramsSpoken(_ v: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.unit.kg.spoken", defaultValue: "\(v) kilograms", bundle: .main)
    }
    static func kilocaloriesSpoken(_ v: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.unit.kcal.spoken", defaultValue: "\(v) kilocalories", bundle: .main)
    }
    static let bpm = LocalizedStringResource("zoop.metric.unit.bpm", defaultValue: "bpm", bundle: .main)
    static func bpmSpoken(_ v: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.unit.bpm.spoken", defaultValue: "\(v) beats per minute", bundle: .main)
    }
    static let breaths = LocalizedStringResource("zoop.metric.unit.breaths", defaultValue: "br/min", bundle: .main)
    static func breathsSpoken(_ v: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.unit.breaths.spoken", defaultValue: "\(v) breaths per minute", bundle: .main)
    }
    static let steps = LocalizedStringResource("zoop.metric.unit.steps", defaultValue: "steps", bundle: .main)
    static func stepsSpoken(_ v: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.unit.steps.spoken", defaultValue: "\(v) steps", bundle: .main)
    }
    static let years = LocalizedStringResource("zoop.metric.unit.years", defaultValue: "yrs", bundle: .main)
    static func yearsSpoken(_ v: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.unit.years.spoken", defaultValue: "\(v) years", bundle: .main)
    }
    static func vo2maxSpoken(_ v: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.unit.vo2max.spoken",
                                defaultValue: "\(v) millilitres per kilogram per minute", bundle: .main)
    }

    // Explainer sheet
    static let whatItIs = LocalizedStringResource("zoop.metric.explainer.whatItIs", defaultValue: "What it is", bundle: .main)
    static let method = LocalizedStringResource("zoop.metric.explainer.method", defaultValue: "How we compute it", bundle: .main)
    static let dataUsed = LocalizedStringResource("zoop.metric.explainer.dataUsed", defaultValue: "Data used", bundle: .main)
    static let confidence = LocalizedStringResource("zoop.metric.explainer.confidence", defaultValue: "Confidence", bundle: .main)
    static let trend = LocalizedStringResource("zoop.metric.explainer.trend", defaultValue: "Your trend", bundle: .main)
    static let contributors = LocalizedStringResource("zoop.metric.explainer.contributors", defaultValue: "What moves it", bundle: .main)
    static let done = LocalizedStringResource("zoop.metric.explainer.done", defaultValue: "Done", bundle: .main)
    static let raises = LocalizedStringResource("zoop.metric.explainer.raises", defaultValue: "Raises it", bundle: .main)
    static let lowers = LocalizedStringResource("zoop.metric.explainer.lowers", defaultValue: "Lowers it", bundle: .main)
    static func nights(_ n: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.data.nights", defaultValue: "\(n) nights", bundle: .main)
    }
    static func days(_ n: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.data.days", defaultValue: "\(n) days", bundle: .main)
    }
    static func samples(_ n: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.data.samples", defaultValue: "\(n) samples", bundle: .main)
    }
    static func source(_ s: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.metric.data.source", defaultValue: "Source: \(s)", bundle: .main)
    }

    /// Resolves a resource in the locale the view is rendering, not the process default.
    static func resolve(_ resource: LocalizedStringResource, locale: Locale) -> String {
        var r = resource
        r.locale = locale
        return String(localized: r)
    }
}
