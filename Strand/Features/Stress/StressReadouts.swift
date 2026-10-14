import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Readout builders (pure)
//
// The Stress screen's one headline number as a `MetricReadout`, its explainer, today's summary and the
// daily trend. All of it is derived from `DaytimeStress` output, so no number here is computed a second
// time. Pure, so the wording and the ranges are unit-testable without a screen.

enum StressReadouts {

    /// Days of history before the typical range counts as the user's own.
    static let minHistoryDays = 7
    /// Stands in for the personal range until then: the medium band of the shared 0-3 scale.
    static let populationRange: ClosedRange<Double> = 1.0...DaytimeStress.highBandFloor

    // MARK: Typical range

    struct Typical: Equatable {
        let range: ClosedRange<Double>
        let isPersonal: Bool
        /// Days of daily levels the range was folded from.
        let days: Int
        /// Mean of those days; nil while the population range stands in, so no delta is drawn against a guess.
        let centre: Double?
    }

    /// Mean plus or minus one standard deviation of the last 30 daily levels before today. Today is left
    /// out so a day is never measured against itself.
    static func typical(daily: DaytimeStress.Daily?) -> Typical {
        let history = (daily?.trend ?? []).filter { $0.day != daily?.day }.suffix(DaytimeStress.dailyBaselineWindow).map(\.level)
        guard history.count >= minHistoryDays else {
            return Typical(range: populationRange, isPersonal: false, days: history.count, centre: nil)
        }
        let mean = history.reduce(0, +) / Double(history.count)
        let variance = history.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(history.count)
        // A very steady user would otherwise get a range too narrow to draw.
        let half = max(variance.squareRoot(), 0.2)
        return Typical(range: max(0, mean - half)...min(3, mean + half), isPersonal: true,
                       days: history.count, centre: mean)
    }

    // MARK: Readout

    static func meaning(level: Double?) -> LocalizedStringResource {
        guard let level else { return StressStrings.meaningNone }
        switch DaytimeStress.Band(level: level) {
        case .low: return StressStrings.meaningLow
        case .medium: return StressStrings.meaningMedium
        case .high: return StressStrings.meaningHigh
        }
    }

    /// `level` is the headline, or the point under the finger while scrubbing.
    static func readout(level: Double?, label: LocalizedStringResource, confidence: ScoreConfidence,
                        typical: Typical) -> MetricReadout {
        guard let level else {
            return MetricReadout(id: .stress, label: label, value: nil, unit: .score(fractionDigits: 1),
                                 verdict: .unavailable(.noData(since: nil)), meaning: StressStrings.meaningNone,
                                 confidence: .building, tint: .stress)
        }
        return MetricReadout(id: .stress, label: label, value: level, unit: .score(fractionDigits: 1),
                             typicalRange: typical.range, rangeIsPersonal: typical.isPersonal,
                             delta: typical.centre.map { level - $0 },
                             verdict: .vital(level, typicalRange: typical.range), meaning: meaning(level: level),
                             confidence: readoutConfidence(confidence, typical: typical), tint: .stress)
    }

    private static func readoutConfidence(_ confidence: ScoreConfidence, typical: Typical) -> MetricReadout.Confidence {
        if !typical.isPersonal { return .calibrating(nightsLeft: max(1, minHistoryDays - typical.days)) }
        switch confidence {
        case .solid: return .solid
        case .building, .calibrating: return .building
        }
    }

    // MARK: Explainer

    static func explanation(daily: DaytimeStress.Daily?, typical: Typical, hrSamples: Int, hrOnly: Bool,
                            now: Date, calendar: Calendar = .current) -> MetricExplanation {
        let dataUsed: MetricExplanation.DataUsed = hrSamples > 0
            ? .init(count: .samples(hrSamples),
                    window: DateInterval(start: calendar.startOfDay(for: now), end: now),
                    source: StressStrings.dataSource)
            : .init(count: .days(daily?.baselineNights ?? 0))
        let trend = (daily?.trend ?? []).suffix(30).compactMap { p in
            day(p.day).map { MetricExplanation.TrendPoint(date: $0, value: p.level) }
        }
        return MetricExplanation(
            whatItIs: StressStrings.whatItIs,
            method: .init(name: StressStrings.methodName,
                          summary: hrOnly ? StressStrings.methodSummaryHROnly : StressStrings.methodSummary),
            dataUsed: dataUsed,
            confidenceReason: typical.isPersonal ? StressStrings.confidenceReason : StressStrings.calibratingReason,
            trend: trend,
            contributors: contributors(daily))
    }

    /// What moved the morning level: a higher resting heart rate and a lower HRV both raise it.
    private static func contributors(_ daily: DaytimeStress.Daily?) -> [MetricExplanation.Contributor] {
        guard let daily else { return [] }
        var out: [MetricExplanation.Contributor] = []
        if let d = daily.restingHRDelta {
            out.append(.init(id: "rhr", label: StressStrings.restingHR,
                             detail: d > 1 ? StressStrings.higherThanUsual : d < -1 ? StressStrings.lowerThanUsual : StressStrings.nearUsual,
                             effect: d > 1 ? .raises : d < -1 ? .lowers : .neutral))
        }
        if let d = daily.hrvDelta {
            out.append(.init(id: "hrv", label: StressStrings.hrv,
                             detail: d > 1 ? StressStrings.higherThanUsual : d < -1 ? StressStrings.lowerThanUsual : StressStrings.nearUsual,
                             effect: d < -1 ? .raises : d > 1 ? .lowers : .neutral))
        }
        return out
    }

    // MARK: Today's summary

    struct DaySummary: Equatable {
        let highest: DaytimeStress.HourPoint
        let lowest: DaytimeStress.HourPoint
        let average: Double
        let highMinutes: Int
    }

    /// From the non-overlapping hours, which are the ones that count time. Nil until an hour is scored.
    static func summary(_ day: DaytimeStress.Result?) -> DaySummary? {
        guard let day, let average = day.dayMean else { return nil }
        let scored = day.scored
        guard let highest = scored.max(by: { ($0.level ?? 0) < ($1.level ?? 0) }),
              let lowest = scored.min(by: { ($0.level ?? 0) < ($1.level ?? 0) }) else { return nil }
        return DaySummary(highest: highest, lowest: lowest, average: average, highMinutes: day.highStressMinutes)
    }

    // MARK: Daily trend

    struct TrendPoint: Equatable, Identifiable {
        let date: Date
        let level: Double
        var id: Date { date }
    }

    /// The newest `days` calendar days of the daily trend, oldest first.
    static func trend(_ daily: DaytimeStress.Daily?, days: Int) -> [TrendPoint] {
        let all = (daily?.trend ?? []).compactMap { p in day(p.day).map { TrendPoint(date: $0, level: p.level) } }
        guard let last = all.last?.date else { return [] }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400 - 3_600)
        return all.filter { $0.date >= cutoff }
    }

    private static func day(_ key: String) -> Date? { dayParser.date(from: key) }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
