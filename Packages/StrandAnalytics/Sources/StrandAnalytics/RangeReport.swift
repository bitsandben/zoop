import Foundation

// Data model for a shareable offline trends report over a date range. Pure, deterministic aggregation with no
// rendering: it turns sparse day->value series ([dayKey: Double], inclusive "yyyy-MM-dd" range) into per-metric
// stats for each metric with a value in range: n, mean, min/max with their days, first- vs second-half mean
// (split by day position), trend (OLS slope per day against a small per-metric threshold, so noise reads flat)
// and latest; plus the range, totalDays and headline strings.
//
// ISO day strings sort chronologically, so everything compares raw strings (as WeeklyDigest does): no Date,
// timezone or locale. Self-contained; does not import WeeklyDigest.

// MARK: - Metric identity

/// The metrics a range report can summarise; `workouts` and `stress` (#457) lead so they rank first.
public enum ReportMetric: String, CaseIterable, Sendable {
    case workouts     // logged workouts per day, count
    case stress       // daily stress score, 0–3 (lower is calmer)
    case recovery     // Charge / recovery, 0–100
    case sleepHours   // time asleep, hours
    case hrv          // heart-rate variability, ms
    case restingHr    // resting heart rate, bpm
    case strain       // Effort / strain, 0–100
    case respRate     // respiratory rate during sleep, breaths/min
    case skinTempDev  // skin-temperature deviation from baseline, °C (signed)

    /// Human label for the metric.
    public var label: String {
        switch self {
        case .workouts:    return "Workouts"
        case .stress:      return "Stress"
        case .recovery:    return "Recovery"
        case .sleepHours:  return "Sleep"
        case .hrv:         return "HRV"
        case .restingHr:   return "Resting HR"
        case .strain:      return "Strain"
        case .respRate:    return "Respiratory rate"
        case .skinTempDev: return "Skin temp"
        }
    }

    /// Display unit suffix (empty for the unitless 0-100 scores and the 0-3 stress index).
    public var unit: String {
        switch self {
        case .recovery, .strain, .stress: return ""
        case .workouts:          return "/day"
        case .sleepHours:        return "h"
        case .hrv:               return "ms"
        case .restingHr:         return "bpm"
        case .respRate:          return "br/min"
        case .skinTempDev:       return "°C"
        }
    }

    /// Whether values show one decimal place rather than whole numbers (workouts is a whole count).
    public var usesOneDecimal: Bool {
        switch self {
        case .sleepHours, .respRate, .skinTempDev, .stress, .workouts: return true
        default:                                                       return false
        }
    }

    /// True when higher is better (resting HR, respiratory rate and stress are lower-is-better); ignored when `framesGoodBad` is false.
    public var higherIsBetter: Bool {
        switch self {
        case .restingHr, .respRate, .stress: return false
        default:                             return true
        }
    }

    /// Whether a move carries a clear good/bad valence. False for signed deviation (skin-temp delta) and workout count; the report then shows direction with no verdict and a neutral chip.
    public var framesGoodBad: Bool {
        switch self {
        case .skinTempDev, .workouts: return false
        default:                      return true
        }
    }

    /// Minimum |slope per day| (metric units) before a trend is rising/falling rather than flat; conservative fixed constants, not personal baselines.
    public var trendSlopeThreshold: Double {
        switch self {
        case .workouts:    return 0.03  // workouts / day (~0.2/week — a clear shift in habit)
        case .stress:      return 0.02  // stress points / day (~0.14/week on the 0–3 scale)
        case .recovery:    return 0.5   // recovery points / day
        case .strain:      return 0.5   // Effort points / day
        case .sleepHours:  return 0.05  // hours / day (~3 min/day)
        case .hrv:         return 0.4   // ms / day
        case .restingHr:   return 0.2   // bpm / day
        case .respRate:    return 0.1   // breaths/min / day (~0.7/week flags illness onset)
        case .skinTempDev: return 0.03  // °C / day (~0.2°C/week)
        }
    }
}

// MARK: - Display units

/// The user's display preferences, resolved by the app layer (#1637): temperature unit (C/F) and Effort axis
/// (native 0-100 / WHOOP 0-21). The exported report must honour them or the PDF shows a different number than the
/// app for the same night. The engine stays pure and never reads UserDefaults; `.stored` is the identity.
public struct ReportDisplayUnits: Equatable, Sendable {
    /// Render temperatures in F. A deviation scales x9/5 with no +32 offset (see `displayValue`).
    public let fahrenheit: Bool
    /// Multiplier onto the stored 0-100 Effort: 1.0 native, 21/100 for WHOOP's 0-21 axis (`UnitFormatter.effortScaleFactor`).
    public let effortFactor: Double

    public init(fahrenheit: Bool, effortFactor: Double) {
        self.fahrenheit = fahrenheit
        self.effortFactor = effortFactor
    }

    /// Values exactly as stored (C, native 0-100 Effort).
    public static let stored = ReportDisplayUnits(fahrenheit: false, effortFactor: 1.0)
}

/// Direction a metric moved across the range (OLS slope vs a small threshold).
public enum ReportTrend: String, Equatable, Sendable {
    case rising
    case falling
    case flat
}

// MARK: - A day-stamped value

/// A value paired with its day ("yyyy-MM-dd").
public struct DayValue: Equatable, Sendable {
    public let day: String
    public let value: Double

    public init(day: String, value: Double) {
        self.day = day
        self.value = value
    }
}

// MARK: - Per-metric range statistics

/// One metric's summary over the range; only produced for metrics with at least one value in range.
public struct MetricRangeStat: Equatable, Sendable {
    public let metric: ReportMetric
    public let n: Int
    public let mean: Double
    /// Lowest value and its day.
    public let min: DayValue
    /// Highest value and its day.
    public let max: DayValue
    /// Mean of the first half of the in-range days (by position).
    public let firstHalfMean: Double
    /// Mean of the second half of the in-range days (by position).
    public let secondHalfMean: Double
    /// Trend direction over the range.
    public let trend: ReportTrend
    /// Value on the latest day present in range.
    public let latest: DayValue

    public init(metric: ReportMetric, n: Int, mean: Double, min: DayValue, max: DayValue,
                firstHalfMean: Double, secondHalfMean: Double, trend: ReportTrend,
                latest: DayValue) {
        self.metric = metric
        self.n = n
        self.mean = mean
        self.min = min
        self.max = max
        self.firstHalfMean = firstHalfMean
        self.secondHalfMean = secondHalfMean
        self.trend = trend
        self.latest = latest
    }

    /// Signed second-half minus first-half mean, in the metric's units.
    public var halfDelta: Double { secondHalfMean - firstHalfMean }
}

// MARK: - Report

/// The shareable trends report over a date range.
public struct RangeReport: Equatable, Sendable {
    /// Inclusive start day.
    public let start: String
    /// Inclusive end day.
    public let end: String
    /// Calendar days the range spans (inclusive); 0 for an invalid range.
    public let totalDays: Int
    /// Per-metric stats in `ReportMetric.allCases` order; metrics with no in-range data are omitted.
    public let metrics: [MetricRangeStat]
    /// Plain-English headline lines, one per present metric, most notable first.
    public let headlines: [String]

    public init(start: String, end: String, totalDays: Int,
                metrics: [MetricRangeStat], headlines: [String]) {
        self.start = start
        self.end = end
        self.totalDays = totalDays
        self.metrics = metrics
        self.headlines = headlines
    }

    /// One metric's stat; nil when it had no in-range data.
    public func stat(_ metric: ReportMetric) -> MetricRangeStat? {
        metrics.first { $0.metric == metric }
    }

    /// True when no metric had a reading in range.
    public var isEmpty: Bool { metrics.isEmpty }
}

// MARK: - Engine

public enum RangeReportEngine {

    // MARK: - Entry point

    /// Builds a RangeReport over the inclusive [start, end] range from each metric's day->value series.
    ///
    /// - Parameters:
    ///   - metrics: per-metric "yyyy-MM-dd" -> value maps; missing metrics and days are simply absent.
    ///   - start: inclusive range start.
    ///   - end: inclusive range end; if it sorts before `start` the range is empty.
    ///   - units: display preferences applied to the rendered `headlines` only (#1637); `MetricRangeStat`s stay in stored units so statistics don't depend on a toggle.
    public static func build(metrics: [ReportMetric: [String: Double]],
                             start: String, end: String,
                             units: ReportDisplayUnits = .stored) -> RangeReport {
        // Valid window requires start <= end (ISO string compare is chronological).
        guard start <= end else {
            return RangeReport(start: start, end: end, totalDays: 0,
                               metrics: [], headlines: [])
        }
        let totalDays = dayCount(start: start, end: end)

        var stats: [MetricRangeStat] = []
        for metric in ReportMetric.allCases {
            let series = metrics[metric] ?? [:]
            // In-range entries in chronological order.
            let ordered = series
                .filter { $0.key >= start && $0.key <= end }
                .sorted { $0.key < $1.key }
            guard !ordered.isEmpty else { continue }   // omit metrics with no data

            let days = ordered.map { $0.key }
            let values = ordered.map { $0.value }
            let n = values.count

            let mn = mean(values)

            // Min/max keep their day; ties go to the earliest day.
            var minDV = DayValue(day: days[0], value: values[0])
            var maxDV = DayValue(day: days[0], value: values[0])
            for i in 1..<n {
                if values[i] < minDV.value { minDV = DayValue(day: days[i], value: values[i]) }
                if values[i] > maxDV.value { maxDV = DayValue(day: days[i], value: values[i]) }
            }

            // Split by position; an odd count gives the larger half to the back of the range so the recent read isn't starved.
            let mid = n / 2
            let firstHalf = Array(values[0..<mid])
            let secondHalf = Array(values[mid..<n])
            // With n == 1 the first half is empty; use the single value so both halves are equal (flat, no fabricated movement).
            let firstMean = firstHalf.isEmpty ? mn : mean(firstHalf)
            let secondMean = secondHalf.isEmpty ? mn : mean(secondHalf)

            let slope = leastSquaresSlope(values)
            let trend = trendFromSlope(slope, threshold: metric.trendSlopeThreshold)

            let latest = DayValue(day: days[n - 1], value: values[n - 1])

            stats.append(MetricRangeStat(
                metric: metric, n: n, mean: mn, min: minDV, max: maxDV,
                firstHalfMean: firstMean, secondHalfMean: secondMean,
                trend: trend, latest: latest))
        }

        let headlines = makeHeadlines(stats, units: units)
        return RangeReport(start: start, end: end, totalDays: totalDays,
                           metrics: stats, headlines: headlines)
    }

    // MARK: - Display conversion

    /// A stored value rendered on the user's chosen axis (#1637). The one place the report converts, shared with the
    /// app's metric cards so they can't disagree. Skin temp is a signed deviation, so F scales by 9/5 with no +32 offset
    /// (as `SkinTempDisplay.numberString`).
    public static func displayValue(_ v: Double, metric: ReportMetric,
                                    units: ReportDisplayUnits) -> Double {
        switch metric {
        case .skinTempDev: return units.fahrenheit ? v * 9.0 / 5.0 : v
        case .strain:      return v * units.effortFactor
        default:           return v
        }
    }

    /// The unit suffix under the user's settings (#1637). Skin temp carries the delta sign (a bare C reads as an absolute
    /// wrist temperature); a rescaled Effort names its denominator.
    public static func displayUnit(_ metric: ReportMetric, units: ReportDisplayUnits) -> String {
        switch metric {
        case .skinTempDev: return units.fahrenheit ? "Δ°F" : "Δ°C"
        case .strain:      return units.effortFactor == 1.0 ? "" : "/ 21"
        default:           return metric.unit
        }
    }

    // MARK: - Headlines

    /// One plain-English line per present metric, most notable first (|half delta| scaled by the trend threshold so different units compare), with good/bad framing.
    static func makeHeadlines(_ stats: [MetricRangeStat],
                              units: ReportDisplayUnits = .stored) -> [String] {
        let ranked = stats.sorted { salience($0) > salience($1) }
        return ranked.map { headline($0, units: units) }
    }

    /// |half delta| normalised by the metric's trend threshold.
    static func salience(_ s: MetricRangeStat) -> Double {
        let t = s.metric.trendSlopeThreshold
        return t > 0 ? abs(s.halfDelta) / t : abs(s.halfDelta)
    }

    /// Renders one metric's headline: trend word, good/bad framing, and the two half means via `displayValue` /
    /// `displayUnit` (#1637). Trend and framing come from stored values, so a display toggle can't flip a verdict.
    static func headline(_ s: MetricRangeStat, units: ReportDisplayUnits = .stored) -> String {
        let word: String
        switch s.trend {
        case .rising:  word = "trending up"
        case .falling: word = "trending down"
        case .flat:    word = "holding steady"
        }
        let frame: String
        if s.trend == .flat || !s.metric.framesGoodBad {
            // Flat, or a signed-deviation metric with no good/bad direction.
            frame = ""
        } else {
            let up = s.trend == .rising
            let good = (up == s.metric.higherIsBetter)
            frame = good ? " - a good sign" : " - worth a look"
        }
        let rawUnit = displayUnit(s.metric, units: units)
        let unit = rawUnit.isEmpty ? "" : " \(rawUnit)"
        let first = displayValue(s.firstHalfMean, metric: s.metric, units: units)
        let second = displayValue(s.secondHalfMean, metric: s.metric, units: units)
        return "\(s.metric.label) is \(word) (avg \(round1(first))\(unit) → "
            + "\(round1(second))\(unit))\(frame)."
    }

    // MARK: - Trend

    /// Maps an OLS slope per day to a direction; within +/- threshold reads flat so a level series never fakes a trend.
    static func trendFromSlope(_ slope: Double, threshold: Double) -> ReportTrend {
        if slope > threshold { return .rising }
        if slope < -threshold { return .falling }
        return .flat
    }

    // MARK: - Day math (timezone/locale-free)

    /// Inclusive day count between two "yyyy-MM-dd" days (1 for the same day); 0 if unparseable or end sorts before start.
    static func dayCount(start: String, end: String) -> Int {
        guard let (sy, sm, sd) = parseYMD(start),
              let (ey, em, ed) = parseYMD(end) else { return 0 }
        let diff = julianDayNumber(ey, em, ed) - julianDayNumber(sy, sm, sd)
        return diff < 0 ? 0 : diff + 1
    }

    /// Parses "yyyy-MM-dd" into validated components (real calendar dates only).
    static func parseYMD(_ s: String) -> (Int, Int, Int)? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= daysInMonth(y, m) else { return nil }
        return (y, m, d)
    }

    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11:           return 30
        case 2: return isLeap(y) ? 29 : 28
        default: return 0
        }
    }

    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0) }

    /// Proleptic-Gregorian date to Julian Day Number (integer-only).
    static func julianDayNumber(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let a = (14 - m) / 12
        let yy = y + 4800 - a
        let mm = m + 12 * a - 3
        return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
    }

    // MARK: - Stats

    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// OLS slope of value vs 0-based index; 0 for < 2 points.
    static func leastSquaresSlope(_ values: [Double]) -> Double {
        let n = values.count
        guard n >= 2 else { return 0 }
        let meanX = Double(n - 1) / 2.0
        let meanY = mean(values)
        var num = 0.0, den = 0.0
        for (i, v) in values.enumerated() {
            let dx = Double(i) - meanX
            num += dx * (v - meanY)
            den += dx * dx
        }
        return den == 0 ? 0 : num / den
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
