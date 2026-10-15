import Foundation

// WeeklyDigest: a deterministic, offline "week in review". Pure and DB-free: from per-metric
// "yyyy-MM-dd" -> value maps it builds a Monday-anchored summary: per-metric SeriesStat, week-over-week
// PeriodComparison (via ComparisonEngine.compare), a "vs baseline" delta against the prior
// `baselineWeeks` complete weeks, a sleep-consistency read, an Effort-vs-Charge balance read, the 1-3
// biggest movers by normalised change, and 1-2 plain-English focal points. Consuming plain maps keeps
// StrandAnalytics decoupled from WhoopStore.
//
// Week math is timezone/locale-free: weekday comes from the day string via Sakamoto's algorithm and week
// windows are inclusive ISO string ranges (string order is chronological), matching AnalyticsEngine's day strings.

// MARK: - Tracked metric

/// The five headline metrics a weekly digest reports on.
public enum WeeklyMetric: String, CaseIterable, Sendable {
    case charge   // recovery, 0–100
    case effort   // strain / Effort, 0–100
    case rest     // sleep performance composite, 0–100
    case rhr      // resting heart rate, bpm
    case hrv      // heart-rate variability, ms

    /// Human label for the metric.
    public var label: String {
        switch self {
        case .charge: return "Charge"
        case .effort: return "Effort"
        case .rest:   return "Rest"
        case .rhr:    return "Resting HR"
        case .hrv:    return "HRV"
        }
    }

    /// Display unit suffix (empty for the unitless 0-100 scores).
    public var unit: String {
        switch self {
        case .charge, .effort, .rest: return ""
        case .rhr: return "bpm"
        case .hrv: return "ms"
        }
    }

    /// True when a HIGHER value is better (resting HR is the lone exception).
    public var higherIsBetter: Bool {
        switch self {
        case .rhr: return false
        default:   return true
        }
    }

    /// A coarse "typical day-to-day range" that normalises week-over-week deltas so movers on different
    /// scales (6 ms HRV vs 4 bpm RHR) can be ranked. Fixed constants, not personal baselines, so ranking is stable.
    public var typicalSpread: Double {
        switch self {
        case .charge: return 12.0   // recovery points
        case .effort: return 12.0   // Effort points
        case .rest:   return 12.0   // Rest points
        case .rhr:    return 4.0    // bpm
        case .hrv:    return 8.0    // ms
        }
    }
}

// MARK: - Per-metric line

/// One metric's line in the weekly digest.
public struct WeeklyMetricSummary: Equatable, Sendable {
    public let metric: WeeklyMetric
    /// This-week stats (Mon-Sun); `.empty` when the week has no readings.
    public let thisWeek: SeriesStat
    /// This week vs the immediately preceding Mon–Sun week.
    public let weekOverWeek: PeriodComparison
    /// Mean over the trailing baseline window (the `baselineWeeks` complete weeks before this one), or nil.
    public let baselineMean: Double?
    /// thisWeek.mean - baselineMean, or nil when baselineMean is nil.
    public let vsBaseline: Double?

    public init(metric: WeeklyMetric, thisWeek: SeriesStat,
                weekOverWeek: PeriodComparison, baselineMean: Double?,
                vsBaseline: Double?) {
        self.metric = metric
        self.thisWeek = thisWeek
        self.weekOverWeek = weekOverWeek
        self.baselineMean = baselineMean
        self.vsBaseline = vsBaseline
    }

    /// Signed week-over-week change in the metric's own units (this − last).
    public var wowDelta: Double { weekOverWeek.delta }

    /// Week-over-week direction as good/bad/flat folding in `higherIsBetter` (a RHR rise reads as worse); 0 when flat or a period is empty.
    public var wowGoodness: Int {
        guard weekOverWeek.direction != 0 else { return 0 }
        let up = weekOverWeek.direction > 0
        let good = (up == metric.higherIsBetter)
        return good ? 1 : -1
    }

    /// The week-over-week change scaled by the metric's typical spread, so movers on different units are comparable.
    public var normalisedMove: Double {
        guard weekOverWeek.current.n > 0, weekOverWeek.previous.n > 0 else { return 0 }
        let s = metric.typicalSpread
        return s > 0 ? wowDelta / s : 0
    }

    /// True when the week-over-week comparison rests on a sparse side: both weeks have a reading but either
    /// has fewer than `WeeklyDigestEngine.minDaysForFocus` days. The UI shows the raw arrow + % but no
    /// confident good/bad verdict (#463: a 43% "drop" off 2 days is not a trend).
    public var isRoughComparison: Bool {
        let cur = weekOverWeek.current.n
        let prev = weekOverWeek.previous.n
        guard cur > 0, prev > 0 else { return false }
        return cur < WeeklyDigestEngine.minDaysForFocus
            || prev < WeeklyDigestEngine.minDaysForFocus
    }
}

// MARK: - Digest

/// The complete week-in-review.
public struct WeeklyDigest: Equatable, Sendable {
    /// The Monday ("yyyy-MM-dd") that anchors this week.
    public let weekStart: String
    /// The Sunday that ends this week.
    public let weekEnd: String
    /// Per-metric summaries, in WeeklyMetric.allCases order.
    public let metrics: [WeeklyMetricSummary]
    /// Distinct days this week that carried at least one reading.
    public let daysWithData: Int
    /// Sleep consistency: SD of this week's Rest values in Rest points (lower = steadier); nil under 2 nights.
    public let sleepConsistencySD: Double?
    /// Effort-vs-Charge balance read for the week.
    public let balance: BalanceRead
    /// 1-2 plain-English focal points, most salient first.
    public let focalPoints: [String]

    public init(weekStart: String, weekEnd: String, metrics: [WeeklyMetricSummary],
                daysWithData: Int, sleepConsistencySD: Double?, balance: BalanceRead,
                focalPoints: [String]) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.metrics = metrics
        self.daysWithData = daysWithData
        self.sleepConsistencySD = sleepConsistencySD
        self.balance = balance
        self.focalPoints = focalPoints
    }

    /// Looks up one metric's summary.
    public func summary(_ metric: WeeklyMetric) -> WeeklyMetricSummary? {
        metrics.first { $0.metric == metric }
    }

    /// True when no metric carried a reading this week (show an empty state instead).
    public var isEmpty: Bool { daysWithData == 0 }
}

/// How this week's Effort (strain) sat against this week's Charge (recovery).
public enum BalanceRead: String, Equatable, Sendable {
    case overreaching   // Effort high vs Charge — leaning into the red
    case balanced       // Effort and Charge roughly tracking
    case underloaded    // Effort low vs Charge — lots in the tank, little spent
    case insufficient   // not enough of both to call it

    /// Plain-English line for the UI.
    public var sentence: String {
        switch self {
        case .overreaching:
            return "Your Effort outpaced your Charge this week: you leaned into the red. Watch for a recovery dip."
        case .balanced:
            return "Effort and Charge tracked together this week: a sustainable load."
        case .underloaded:
            return "You carried more Charge than you spent this week: there's room to push if you want it."
        case .insufficient:
            return "Not enough Effort and Charge days this week to read your balance."
        }
    }
}

public enum WeeklyDigestEngine {

    /// How many complete weeks before "this week" form the vs-baseline comparison.
    public static let baselineWeeks: Int = 4
    /// Minimum days each side needs before a week-over-week move is surfaced as a focal point.
    public static let minDaysForFocus: Int = 3

    // MARK: - Entry point

    /// Builds the weekly digest anchored on the Monday of the week containing `anchorDay` ("yyyy-MM-dd").
    ///
    /// - Parameters:
    ///   - byMetric: per-metric day-to-value maps; missing metrics/days are simply absent.
    ///   - anchorDay: any day in the target week (snapped to its Monday); unparseable yields an empty digest.
    ///   - effortDisplayFactor: multiplier on EFFORT averages in the focal-point sentences ONLY, for users on
    ///     the 0-21 scale (#268). Percent changes are scale-invariant. Display-only.
    public static func build(byMetric: [WeeklyMetric: [String: Double]],
                             anchorDay: String,
                             effortDisplayFactor: Double = 1.0) -> WeeklyDigest {
        guard let monday = mondayOfWeek(containing: anchorDay) else {
            return emptyDigest(weekStart: anchorDay, weekEnd: anchorDay)
        }
        let sunday = addDays(monday, 6)
        let lastMonday = addDays(monday, -7)
        let lastSunday = addDays(monday, -1)

        // Baseline: the `baselineWeeks` complete weeks ending the day before last week starts (never overlaps this or last week).
        let baselineEnd = addDays(lastMonday, -1)               // Sunday before last week
        let baselineStart = addDays(lastMonday, -7 * baselineWeeks)

        var summaries: [WeeklyMetricSummary] = []
        var daysSeen: Set<String>? = []

        for metric in WeeklyMetric.allCases {
            let series = byMetric[metric] ?? [:]

            var noAccum: Set<String>? = nil
            let thisVals = valuesInRange(series, start: monday, end: sunday, daysSeen: &daysSeen)
            let lastVals = valuesInRange(series, start: lastMonday, end: lastSunday, daysSeen: &noAccum)
            let baseVals = valuesInRange(series, start: baselineStart, end: baselineEnd, daysSeen: &noAccum)

            let thisStat = ComparisonEngine.stat(thisVals)
            let wow = ComparisonEngine.compare(current: thisVals, previous: lastVals)
            let baseMean: Double? = baseVals.isEmpty ? nil
                : baseVals.reduce(0, +) / Double(baseVals.count)
            let vsBase: Double? = baseMean.map { thisStat.mean - $0 }

            summaries.append(WeeklyMetricSummary(
                metric: metric, thisWeek: thisStat, weekOverWeek: wow,
                baselineMean: baseMean, vsBaseline: vsBase))
        }

        // Sleep consistency: SD of this week's Rest series.
        let restStat = summaries.first { $0.metric == .rest }?.thisWeek
        let restConsistency: Double? = (restStat?.n ?? 0) >= 2 ? restStat?.stdev : nil

        let balance = balanceRead(summaries)
        let focal = focalPoints(summaries: summaries, balance: balance,
                                consistencySD: restConsistency,
                                effortDisplayFactor: effortDisplayFactor)

        return WeeklyDigest(
            weekStart: monday, weekEnd: sunday, metrics: summaries,
            daysWithData: (daysSeen ?? []).count, sleepConsistencySD: restConsistency,
            balance: balance, focalPoints: focal)
    }

    // MARK: - Balance read

    /// Gap (Effort mean minus Charge mean, both 0-100) beyond which the week reads "overreaching" (above) or
    /// "underloaded" (below); within it, "balanced". Needs `minDaysForFocus` days of each, else `.insufficient`.
    static let balanceBand: Double = 10.0

    static func balanceRead(_ summaries: [WeeklyMetricSummary]) -> BalanceRead {
        guard
            let effort = summaries.first(where: { $0.metric == .effort })?.thisWeek,
            let charge = summaries.first(where: { $0.metric == .charge })?.thisWeek,
            effort.n >= minDaysForFocus, charge.n >= minDaysForFocus
        else { return .insufficient }

        let gap = effort.mean - charge.mean
        if gap > balanceBand { return .overreaching }
        if gap < -balanceBand { return .underloaded }
        return .balanced
    }

    // MARK: - Focal points

    /// Half a "typical spread" of normalised movement; the bar for a week-over-week mover to surface.
    static let focusThreshold: Double = 0.5   // half a "typical spread" of movement

    static func focalPoints(summaries: [WeeklyMetricSummary],
                            balance: BalanceRead,
                            consistencySD: Double?,
                            effortDisplayFactor: Double = 1.0) -> [String] {
        // Rank movers by |normalised move|; both weeks need enough days.
        let movers = summaries
            .filter { $0.weekOverWeek.current.n >= minDaysForFocus
                   && $0.weekOverWeek.previous.n >= minDaysForFocus
                   && abs($0.normalisedMove) >= focusThreshold }
            .sorted { abs($0.normalisedMove) > abs($1.normalisedMove) }

        var lines: [String] = []

        if let top = movers.first {
            lines.append(moverSentence(top, effortDisplayFactor: effortDisplayFactor))
        }

        // Supporting line: a non-trivial balance read, else the 2nd mover.
        if balance == .overreaching || balance == .underloaded {
            lines.append(balance.sentence)
        } else if movers.count >= 2 {
            lines.append(moverSentence(movers[1], effortDisplayFactor: effortDisplayFactor))
        }

        // Nothing cleared the mover bar. Distinguish: the CURRENT or PREVIOUS week is too sparse to call a
        // trend (saying "a steady week" there contradicts the per-metric chips, #463), or the week has enough
        // days and genuinely held even.
        if lines.isEmpty {
            let currentDays = summaries.map { $0.weekOverWeek.current.n }.max() ?? 0
            let prevDays = summaries.map { $0.weekOverWeek.previous.n }.max() ?? 0
            if currentDays >= 1 && currentDays < minDaysForFocus {
                let dayWord = currentDays == 1 ? "day" : "days"
                lines.append("Only \(currentDays) \(dayWord) into this week so far, too early to "
                    + "call a week-over-week trend yet.")
            } else if currentDays >= minDaysForFocus, prevDays >= 1, prevDays < minDaysForFocus {
                let dayWord = prevDays == 1 ? "day" : "days"
                lines.append("Last week only had \(prevDays) \(dayWord) of data, so week-over-week "
                    + "changes are rough, not a trend.")
            } else if let sd = consistencySD, sd <= 6.0 {
                lines.append("A steady week: Rest held even (±\(round1(sd)) pts) and nothing moved much.")
            } else {
                lines.append("A steady week: no metric moved meaningfully from last week.")
            }
        }

        return Array(lines.prefix(2))
    }

    /// Renders one mover as a plain-English sentence with good/bad framing. `effortDisplayFactor` rescales
    /// EFFORT averages for display only.
    static func moverSentence(_ s: WeeklyMetricSummary,
                              effortDisplayFactor: Double = 1.0) -> String {
        let f = s.metric == .effort ? effortDisplayFactor : 1.0
        let directionWord = s.wowDelta > 0 ? "up" : (s.wowDelta < 0 ? "down" : "flat")
        let magnitude: String
        if let pct = s.weekOverWeek.pctChange, abs(pct) >= 1 {
            magnitude = "\(roundedInt(abs(pct)))%"
        } else {
            magnitude = "\(round1(abs(s.wowDelta) * f))\(s.metric.unit.isEmpty ? " pts" : " " + s.metric.unit)"
        }
        let frame: String
        switch s.wowGoodness {
        case 1:  frame = ", a good sign"
        case -1: frame = ", worth a look"
        default: frame = ""
        }
        let thisAvg = roundedInt(s.thisWeek.mean * f)
        let lastAvg = roundedInt(s.weekOverWeek.previous.mean * f)
        return "\(s.metric.label) is \(directionWord) \(magnitude) week over week"
            + " (avg \(thisAvg) vs \(lastAvg))\(frame)."
    }

    // MARK: - Range extraction

    /// Collects the values of `series` within [start, end] inclusive, in chronological order so the SeriesStat
    /// slope is meaningful. A non-nil `daysSeen` records the days that carried a value.
    static func valuesInRange(_ series: [String: Double], start: String, end: String,
                              daysSeen: inout Set<String>?) -> [Double] {
        let inRange = series.filter { $0.key >= start && $0.key <= end }
        if daysSeen != nil {
            for k in inRange.keys { daysSeen?.insert(k) }
        }
        // Sorted by day string so the slope is chronological regardless of dict order.
        return inRange.sorted { $0.key < $1.key }.map { $0.value }
    }

    // MARK: - Pure week math (timezone/locale-free)

    /// The Monday of the week containing `day`; nil if unparseable.
    public static func mondayOfWeek(containing day: String) -> String? {
        guard let (y, m, d) = parseYMD(day), let w = weekday(y, m, d) else { return nil }
        // weekday 0=Sunday...6=Saturday; days since Monday: Mon=0...Sun=6.
        let sinceMonday = (w + 6) % 7
        return addDays(day, -sinceMonday)
    }

    /// Adds `n` days (may be negative) to a "yyyy-MM-dd" day; returns the input if unparseable.
    public static func addDays(_ day: String, _ n: Int) -> String {
        guard let (y, m, d) = parseYMD(day) else { return day }
        let jdn = julianDayNumber(y, m, d) + n
        let (ny, nm, nd) = fromJulianDayNumber(jdn)
        return formatYMD(ny, nm, nd)
    }

    /// Sakamoto's day-of-week: 0=Sunday...6=Saturday; nil for an invalid date.
    static func weekday(_ y: Int, _ m: Int, _ d: Int) -> Int? {
        guard (1...12).contains(m), d >= 1, d <= daysInMonth(y, m) else { return nil }
        let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        var yy = y
        if m < 3 { yy -= 1 }
        return (yy + yy / 4 - yy / 100 + yy / 400 + t[m - 1] + d) % 7
    }

    /// Days in a month, leap-year aware.
    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11:           return 30
        case 2: return isLeap(y) ? 29 : 28
        default: return 0
        }
    }

    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0) }

    /// Parses "yyyy-MM-dd" into validated integer components. Public so UI layers can format week-range labels.
    public static func parseYMD(_ s: String) -> (Int, Int, Int)? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= daysInMonth(y, m) else { return nil }
        return (y, m, d)
    }

    /// Zero-padded "yyyy-MM-dd".
    static func formatYMD(_ y: Int, _ m: Int, _ d: Int) -> String {
        let yy = y < 1000 ? String(format: "%04d", y) : "\(y)"
        let mm = m < 10 ? "0\(m)" : "\(m)"
        let dd = d < 10 ? "0\(d)" : "\(d)"
        return "\(yy)-\(mm)-\(dd)"
    }

    /// Proleptic-Gregorian date to Julian Day Number (integer-only, timezone-free), for date arithmetic.
    static func julianDayNumber(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let a = (14 - m) / 12
        let yy = y + 4800 - a
        let mm = m + 12 * a - 3
        return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
    }

    /// Inverse of `julianDayNumber`.
    static func fromJulianDayNumber(_ jdn: Int) -> (Int, Int, Int) {
        let a = jdn + 32044
        let b = (4 * a + 3) / 146097
        let c = a - (146097 * b) / 4
        let dd = (4 * c + 3) / 1461
        let e = c - (1461 * dd) / 4
        let mm = (5 * e + 2) / 153
        let day = e - (153 * mm + 2) / 5 + 1
        let month = mm + 3 - 12 * (mm / 10)
        let year = 100 * b + dd - 4800 + mm / 10
        return (year, month, day)
    }

    // MARK: - Empty digest

    static func emptyDigest(weekStart: String, weekEnd: String) -> WeeklyDigest {
        let summaries = WeeklyMetric.allCases.map { m in
            WeeklyMetricSummary(metric: m, thisWeek: .empty,
                                weekOverWeek: ComparisonEngine.compare(current: [], previous: []),
                                baselineMean: nil, vsBaseline: nil)
        }
        return WeeklyDigest(weekStart: weekStart, weekEnd: weekEnd, metrics: summaries,
                            daysWithData: 0, sleepConsistencySD: nil,
                            balance: .insufficient, focalPoints: [])
    }

    // MARK: - Formatting helpers

    static func roundedInt(_ x: Double) -> Int { Int(x.rounded()) }
    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
