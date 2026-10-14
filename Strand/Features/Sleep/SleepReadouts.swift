import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

/// One Sleep number with everything its explainer shows.
struct SleepMetric: Identifiable {
    let readout: MetricReadout
    let explanation: MetricExplanation
    var id: MetricID { readout.id }
}

// MARK: - Readout builders (pure)
//
// Every number on the Sleep screen is built here from stored rows: value, personal range from the
// nights before it, verdict, meaning, and the explainer's data window and 30-day trend. Views only
// render the results.

enum SleepReadouts {

    /// A day-keyed history: oldest first, tonight excluded.
    typealias History = [(day: String, value: Double)]

    /// Readout plus explanation for `value` against the range folded from `history`.
    static func metric(id: MetricID, label: LocalizedStringResource, value: Double?, unit: MetricUnit,
                       history: History, cfg: MetricCfg, population: ClosedRange<Double>,
                       tint: MetricReadout.Tint = .sleep, valueDay: String? = nil,
                       meaning: ((MetricVerdict) -> LocalizedStringResource)? = nil) -> SleepMetric {
        let range = SleepPersonalRange.resolve(history: history.map { Optional($0.value) }, cfg: cfg,
                                               population: population,
                                               lastSample: history.last.map { date($0.day) })
        let readout = range.readout(id: id, label: label, value: value, unit: unit, tint: tint,
                                    meaning: meaning ?? { SleepMeanings.meaning(id, $0) })
        return SleepMetric(readout: readout,
                           explanation: explanation(id, range: range, history: history,
                                                    tonight: value.map { (valueDay ?? "", $0) }))
    }

    static func explanation(_ id: MetricID, range: SleepPersonalRange, history: History,
                            tonight: (day: String, value: Double)?,
                            contributors: [MetricExplanation.Contributor] = [],
                            extraReason: LocalizedStringResource? = nil) -> MetricExplanation {
        var points = Array(history.suffix(29))
        if let tonight, !tonight.day.isEmpty { points.append(tonight) }
        let trend = points.map { MetricExplanation.TrendPoint(date: date($0.day), value: $0.value) }
        let window = trend.first.flatMap { first in trend.last.map { DateInterval(start: first.date, end: $0.date) } }
        let copy = SleepExplanations.copy(id)
        return MetricExplanation(
            whatItIs: copy.whatItIs, method: copy.method,
            dataUsed: .init(count: .nights(range.nights), window: window),
            confidenceReason: extraReason ?? (range.isPersonal ? SleepStrings.personalRangeReason
                                                              : SleepStrings.populationRangeReason),
            trend: trend, contributors: contributors)
    }

    /// Rows strictly before `day`, mapped through `pick`, keeping only finite values.
    static func history(_ days: [DailyMetric], before day: String, _ pick: (DailyMetric) -> Double?) -> History {
        days.compactMap { d in
            guard d.day < day, let v = pick(d), v.isFinite else { return nil }
            return (d.day, v)
        }
    }

    // MARK: Day keys

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ day: String) -> Date { dayParser.date(from: day) ?? Date() }

    // MARK: Shared row transforms

    /// Efficiency in percent; stored rows mix 0–1 and 0–100.
    static func efficiencyPct(_ raw: Double?) -> Double? {
        guard let raw else { return nil }
        return raw <= 1.0 ? raw * 100 : raw
    }

    /// Awake minutes of a stored row, from asleep minutes and efficiency.
    static func awakeMin(_ d: DailyMetric) -> Double? {
        guard let asleep = d.totalSleepMin, asleep > 0, let eff = efficiencyPct(d.efficiency), eff > 0 else { return nil }
        return max(0, asleep / (eff / 100) - asleep)
    }

    /// The sleep score of a stored day: the imported WHOOP figure, else the resolved composite.
    static func score(_ d: DailyMetric, imported: [String: ImportedSleepFigures]) -> Double? {
        imported[d.day]?.performancePct ?? AnalyticsEngine.Rest.composite(daily: d)
    }

    /// Locale-aware "7 h 43 min" for prose.
    static func durationText(seconds: Double) -> String {
        MetricUnit.duration.format(seconds, locale: AppLanguage.activeLocale)
    }
}
