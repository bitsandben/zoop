import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Stress, Energy Bank, dashboard and fitness-age readouts
//
// Pure builders over values the model loaded. Every number is placed against the user's own range;
// a population range only stands in while too few own days exist, and is labelled as such (§1.1).

enum TodayBodyReadouts {

    // MARK: Stress

    /// DaytimeStress scores against the wearer's own resting baseline, so its medium band (1 to 2 on the
    /// 0–3 scale, `DaytimeStress.Band`) is their typical range.
    static let stressTypical: ClosedRange<Double> = 1.0...DaytimeStress.highBandFloor

    /// `headline` is `DaytimeStress.headline` for today, or a past day's own daily level.
    static func stress(_ headline: Assessment<Double, DaytimeStress.HeadlineSource>) -> MetricReadout {
        let unit = MetricUnit.score(fractionDigits: 1)
        guard let level = headline.value else {
            return MetricReadout(id: .stress, label: TodayCopy.stress, value: nil, unit: unit,
                                 verdict: .unavailable(.noData(since: nil)), meaning: TodayCopy.stressNoData,
                                 tint: .stress)
        }
        let word = rangeVerdict(level, stressTypical)
        return MetricReadout(id: .stress, label: TodayCopy.stress, value: level, unit: unit,
                             typicalRange: stressTypical, verdict: word.verdict,
                             meaning: TodayCopy.vitalMeaning(.stress, word),
                             confidence: TodayRings.confidence(headline.confidence), tint: .stress)
    }

    /// A past day has no intraday curve: it reads that day's own daily level, or nothing (#P8). The
    /// carry inside `DaytimeStress.daily` must not put another day's level on this one.
    static func pastDayStress(_ daily: DaytimeStress.Daily?, dayKey: String) -> Assessment<Double, DaytimeStress.HeadlineSource> {
        guard let daily, daily.day == dayKey else {
            return Assessment(value: nil, confidence: .calibrating, reason: .none)
        }
        return DaytimeStress.headline(hours: [], daily: daily)
    }

    // MARK: Energy Bank

    /// The Energy Bank is a heuristic (see `EnergyBank`), so it never reads as more than provisional.
    static func energy(_ result: EnergyBank.Result?) -> MetricReadout {
        guard let result else {
            return MetricReadout(id: .energyBank, label: TodayCopy.energy, value: nil, unit: .score,
                                 verdict: .unavailable(.noData(since: nil)), meaning: TodayCopy.energyNoData)
        }
        let band = ScoreBand(score: result.current)
        return MetricReadout(id: .energyBank, label: TodayCopy.energy, value: result.current, unit: .score,
                             verdict: .score(band), meaning: TodayCopy.energyMeaning(band),
                             confidence: .building, tint: .recovery)
    }

    // MARK: Dashboard

    /// Own days needed before a personal range replaces the population one.
    static let minOwnDays = 4

    /// Steps or active calories against the last 14 complete days. Today is partial, so it is judged
    /// against full days on purpose: the copy says "so far" for the below case.
    static func dailyCount(id: MetricID, value: Double?, history: [Double], unit: MetricUnit,
                           population: ClosedRange<Double>) -> MetricReadout {
        let copy: VitalCopyID = id == .steps ? .steps : .calories
        let label = id == .steps ? TodayCopy.steps : TodayCopy.calories
        guard let value else {
            return MetricReadout(id: id, label: label, value: nil, unit: unit,
                                 verdict: .unavailable(.noData(since: nil)),
                                 meaning: id == .steps ? TodayCopy.stepsNoData : TodayCopy.caloriesNoData)
        }
        let personal = typicalRange(history)
        let range = personal ?? population
        let word = rangeVerdict(value, range)
        let confidence: MetricReadout.Confidence = personal == nil
            ? .calibrating(nightsLeft: max(1, minOwnDays - history.count)) : .solid
        return MetricReadout(id: id, label: label, value: value, unit: unit, typicalRange: range,
                             rangeIsPersonal: personal != nil, verdict: word.verdict,
                             meaning: TodayCopy.vitalMeaning(copy, word), confidence: confidence)
    }

    /// The newest weigh-in on or before the day, against the weigh-ins of the 90 days before it.
    /// Weight has no population range: with too few weigh-ins it reads typical and provisional.
    static func weight(latest: (day: String, kg: Double)?, earlier: [Double], selectedDay: String) -> MetricReadout {
        guard let latest else {
            return MetricReadout(id: .weight, label: TodayCopy.weight, value: nil, unit: .kilograms,
                                 verdict: .unavailable(.noData(since: nil)), meaning: TodayCopy.weightNoData)
        }
        let range = typicalRange(earlier, minCount: 3)
        let word = range.map { rangeVerdict(latest.kg, $0) } ?? .typical
        var confidence: MetricReadout.Confidence = range == nil ? .building : .solid
        if daysBetween(latest.day, selectedDay) > 14, let since = TodayLogic.dayKeyParser.date(from: latest.day) {
            confidence = .stale(since: since)
        }
        return MetricReadout(id: .weight, label: TodayCopy.weight, value: latest.kg, unit: .kilograms,
                             typicalRange: range, verdict: word.verdict,
                             meaning: TodayCopy.vitalMeaning(.weight, word), confidence: confidence)
    }

    // MARK: Fitness age

    /// Fitness age against the profile age: within a year either side reads as the same, and that span
    /// is the range the bar draws, so the marker shows how far from your age you sit.
    static func fitnessAge(latest: (day: String, value: Double)?, age: Int, selectedDay: String) -> MetricReadout {
        guard let latest else {
            return MetricReadout(id: .fitnessAge, label: TodayCopy.fitnessAge, value: nil, unit: .years,
                                 verdict: .unavailable(.noData(since: nil)), meaning: TodayCopy.fitnessAgeNoData)
        }
        let ageRange: ClosedRange<Double>? = age > 0 ? Double(age - 1)...Double(age + 1) : nil
        let word = ageRange.map { rangeVerdict(latest.value, $0) } ?? .typical
        // Fitness age is scored weekly, so only a value older than two weeks is out of date.
        let confidence: MetricReadout.Confidence = daysBetween(latest.day, selectedDay) > 14
            ? .stale(since: TodayLogic.dayKeyParser.date(from: latest.day) ?? Date()) : .solid
        return MetricReadout(id: .fitnessAge, label: TodayCopy.fitnessAge, value: latest.value,
                             unit: .years, typicalRange: ageRange, verdict: word.verdict,
                             meaning: TodayCopy.vitalMeaning(.fitnessAge, word), confidence: confidence)
    }

    // MARK: Helpers

    /// Mean ± 1 SD (the §1.1 typical range), nil below `minCount` values.
    static func typicalRange(_ values: [Double], minCount: Int = minOwnDays) -> ClosedRange<Double>? {
        guard values.count >= minCount else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        let sd = variance.squareRoot()
        return max(0, mean - sd)...(mean + sd)
    }

    static func rangeVerdict(_ value: Double, _ range: ClosedRange<Double>) -> RangeVerdict {
        if value > range.upperBound { return .above }
        if value < range.lowerBound { return .below }
        return .typical
    }

    static func daysBetween(_ from: String, _ to: String) -> Int {
        guard let a = TodayLogic.dayKeyParser.date(from: from),
              let b = TodayLogic.dayKeyParser.date(from: to) else { return 0 }
        return Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0
    }
}
