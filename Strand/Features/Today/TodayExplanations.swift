import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Explainer content for every Today number
//
// What each metric is, how it is computed and which data went in. The trend is the last 30 days the
// model already loaded; the copy is fixed per metric, so the explainer never improvises.

enum TodayExplanations {

    /// The 30-day series and provenance the model hands over, keyed by metric.
    struct Inputs: Equatable {
        var trends: [MetricID: [MetricExplanation.TrendPoint]] = [:]
        /// Strap or import the scores came from ("WHOOP", "Apple Watch").
        var scoreSource: String?
        /// Recovery's signed drivers for the shown night (`ChargeBreakdownWiring`).
        var recoveryDrivers: [ChargeDriver] = []
    }

    static func explanation(for id: MetricID, inputs: Inputs) -> MetricExplanation {
        let trend = inputs.trends[id] ?? []
        let copy = Self.copy(id)
        let source = [.recovery, .sleepScore, .strain, .stress].contains(id) ? inputs.scoreSource : nil
        let count: MetricExplanation.DataUsed.Count = [.recovery, .sleepScore].contains(id)
            ? .nights(trend.count) : .days(trend.count)
        let window = trend.first.flatMap { first in trend.last.map { DateInterval(start: first.date, end: $0.date) } }
        return MetricExplanation(
            whatItIs: copy.what,
            method: .init(name: copy.method, summary: copy.how, citation: copy.citation),
            dataUsed: .init(count: count, window: window, source: source),
            trend: trend,
            contributors: id == .recovery ? inputs.recoveryDrivers.map(contributor) : [])
    }

    private static func contributor(_ d: ChargeDriver) -> MetricExplanation.Contributor {
        let detail = d.baselineText.isEmpty ? d.valueText : "\(d.valueText) · \(d.baselineText)"
        return .init(id: d.label, label: LocalizedStringResource(String.LocalizationValue(d.label)),
                     detail: LocalizedStringResource(String.LocalizationValue(detail)),
                     effect: d.deltaPoints > 0 ? .raises : (d.deltaPoints < 0 ? .lowers : .neutral))
    }

    private struct Copy {
        let what: LocalizedStringResource
        let method: LocalizedStringResource
        let how: LocalizedStringResource
        var citation: String?
    }

    private static func r(_ key: StaticString, _ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: value)
    }

    private static func copy(_ id: MetricID) -> Copy {
        switch id {
        case .recovery:
            return Copy(what: r("zoop.today.explain.recovery.what", "How ready your body is for load today, from last night's physiology."),
                        method: r("zoop.today.explain.recovery.method", "Recovery score"),
                        how: r("zoop.today.explain.recovery.how", "HRV, resting heart rate and breathing rate against your own 21-night baseline, plus sleep."),
                        citation: "Plews et al., 2012")
        case .sleepScore:
            return Copy(what: r("zoop.today.explain.sleep.what", "How well last night met your sleep need, from 0 to 100."),
                        method: r("zoop.today.explain.sleep.method", "Sleep performance"),
                        how: r("zoop.today.explain.sleep.how", "Time asleep against your need, sleep efficiency and stages; an imported score is used as is."))
        case .strain:
            return Copy(what: r("zoop.today.explain.strain.what", "How much load your heart carried today, from rest and activity."),
                        method: r("zoop.today.explain.strain.method", "Heart-rate reserve load"),
                        how: r("zoop.today.explain.strain.how", "Time in each heart-rate zone, weighted by intensity, on a scale that gets harder to climb."),
                        citation: "Banister, 1991")
        case .stress:
            return Copy(what: r("zoop.today.explain.stress.what", "How strained your nervous system is right now, from 0 to 3."),
                        method: r("zoop.today.explain.stress.method", "Daytime stress"),
                        how: r("zoop.today.explain.stress.how", "Each waking hour's heart rate and HRV against your own resting baseline; workouts are left out."))
        case .energyBank:
            return Copy(what: r("zoop.today.explain.energy.what", "An estimate of the energy you have left today, from 0 to 100."),
                        method: r("zoop.today.explain.energy.method", "Energy Bank"),
                        how: r("zoop.today.explain.energy.how", "Starts from last night's recovery, then rest fills it and activity drains it; a heuristic, not validated."))
        case .steps:
            return Copy(what: r("zoop.today.explain.steps.what", "Steps walked on this day."),
                        method: r("zoop.today.explain.steps.method", "Step count"),
                        how: r("zoop.today.explain.steps.how", "The strap's count, else Apple Health, else an estimate from motion; compared with your last 14 days."))
        case .weight:
            return Copy(what: r("zoop.today.explain.weight.what", "Your latest weigh-in on or before this day."),
                        method: r("zoop.today.explain.weight.method", "Apple Health weight"),
                        how: r("zoop.today.explain.weight.how", "Read from Apple Health and compared with your weigh-ins of the last 90 days."))
        case .fitnessAge:
            return Copy(what: r("zoop.today.explain.fitnessAge.what", "The age your fitness corresponds to, next to your actual age."),
                        method: r("zoop.today.explain.fitnessAge.method", "Fitness age"),
                        how: r("zoop.today.explain.fitnessAge.how", "Estimated VO₂max from resting heart rate and activity, matched to age norms each week."),
                        citation: "Nes et al., 2013")
        default:
            return Copy(what: r("zoop.today.explain.calories.what", "Energy burned through activity on this day, beyond resting needs."),
                        method: r("zoop.today.explain.calories.method", "Active energy"),
                        how: r("zoop.today.explain.calories.how", "Apple Health's active energy, else Zoop's estimate from your heart rate; compared with your last 14 days."))
        }
    }
}

extension MetricID {
    static let activeCalories: MetricID = "active_calories"
    static let energyBank: MetricID = "energy_bank"
}
