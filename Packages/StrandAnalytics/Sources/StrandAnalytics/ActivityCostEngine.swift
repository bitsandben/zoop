import Foundation

// ActivityCostEngine: what each sport costs your next-morning Charge.
// Pure and deterministic. Per sport: baselineMean (mean Charge over untouched rest days,
// shared by all sports) minus the mean D+1 Charge after tagged days = delta; positive
// means the morning after sits below baseline. daysToBaseline is the smallest k whose
// averaged forward trajectory is within `tolerance` of baseline (nil if never).
// Sports with fewer than minSessions pairs are omitted; confidence is .building/.solid.
// Ranking: |delta| desc, .solid before .building, then sport name.

// MARK: - Result

/// One sport's recovery cost: how far below your rest baseline next-morning Charge sits after
/// a session, and how long it takes to bounce back.
public struct ActivityCost: Equatable, Sendable {
    /// The sport key as tagged on the day.
    public let sport: String
    /// Baseline minus mean next-morning Charge, in points. Positive = the morning after sits below baseline.
    public let delta: Double
    /// Mean D+1 Charge over tagged days that had one, 0-100.
    public let meanNextMorning: Double
    /// Mean rest-day Charge this sport is measured against (shared across sports), 0-100.
    public let baselineMean: Double
    /// Days for the averaged trajectory to return within `tolerance` of baseline; nil if it never does in the window.
    public let daysToBaseline: Int?
    /// Tagged days that contributed a D+1 value.
    public let n: Int
    /// Per-result certainty tier.
    public let confidence: ScoreConfidence

    public init(sport: String, delta: Double, meanNextMorning: Double, baselineMean: Double,
                daysToBaseline: Int?, n: Int, confidence: ScoreConfidence) {
        self.sport = sport
        self.delta = delta
        self.meanNextMorning = meanNextMorning
        self.baselineMean = baselineMean
        self.daysToBaseline = daysToBaseline
        self.n = n
        self.confidence = confidence
    }

    /// Plain-English summary; drops the bounce-back clause when `daysToBaseline` is nil and says
    /// "barely move" under a point either way.
    public func sentence() -> String {
        let mag = abs(delta)
        let points = ActivityCostEngine.roundToInt(mag)
        if mag < ActivityCostEngine.barelyMovesPoints {
            return "Sessions like this barely move your next-day Charge (n=\(n))."
        }
        let direction = delta >= 0 ? "cost you" : "lift"
        let head = "Sessions like this usually \(direction) about \(points) Charge "
            + "point\(points == 1 ? "" : "s") the next morning"
        if let days = daysToBaseline {
            return head + " and take about \(days) day\(days == 1 ? "" : "s") to bounce back (n=\(n))."
        }
        return head + " (n=\(n))."
    }
}

// MARK: - Engine

public enum ActivityCostEngine {

    // MARK: Tunables (documented, deterministic — NOT learned)

    /// Pairs below which a sport is omitted.
    public static let minSessions: Int = 4
    /// Pairs at/above which confidence is `.solid` (else `.building`).
    public static let solidSessions: Int = 8
    /// Days forward the bounce-back trajectory is probed.
    public static let maxLookahead: Int = 7
    /// Charge points within baseline that count as recovered.
    public static let tolerance: Double = 3.0
    /// |delta| under this reads as "barely moves".
    public static let barelyMovesPoints: Double = 1.0

    // MARK: - Evaluate

    /// Compute each sport's recovery cost from tagged activity days (per sport, a set of
    /// "yyyy-MM-dd" keys) and daily Charge. Returns sports that cleared `minSessions`, ranked.
    public static func evaluate(activityDaysBySport: [String: Set<String>],
                                recoveryByDay: [String: Double]) -> [ActivityCost] {
        guard !activityDaysBySport.isEmpty, !recoveryByDay.isEmpty else { return [] }

        // Rest days exclude tagged days and each tagged day's forward window: the mornings after
        // a session are the days the cost suppresses, so counting them would understate every cost.
        var activeUnion: Set<String> = []
        for (_, days) in activityDaysBySport { activeUnion.formUnion(days) }
        var affected = activeUnion
        for day in activeUnion {
            for k in 1...maxLookahead {
                if let d = CorrelationEngine.shiftDay(day, by: k) { affected.insert(d) }
            }
        }
        var restValues: [Double] = []
        for (day, value) in recoveryByDay where !affected.contains(day) {
            restValues.append(value)
        }
        // No untouched days means no baseline.
        guard !restValues.isEmpty else { return [] }
        let baselineMean = mean(restValues)

        var results: [ActivityCost] = []
        // Sorted for deterministic order regardless of dictionary iteration.
        for sport in activityDaysBySport.keys.sorted() {
            let taggedDays = activityDaysBySport[sport]!

            var nextMornings: [Double] = []
            for day in taggedDays {
                guard let d1 = CorrelationEngine.shiftDay(day, by: 1),
                      let v = recoveryByDay[d1] else { continue }
                nextMornings.append(v)
            }
            let n = nextMornings.count
            // Thin sports are omitted rather than fabricated.
            if n < minSessions { continue }

            let meanNextMorning = mean(nextMornings)
            let delta = baselineMean - meanNextMorning
            let daysToBaseline = forwardDaysToBaseline(taggedDays: taggedDays,
                                                       recoveryByDay: recoveryByDay,
                                                       baselineMean: baselineMean)
            let confidence: ScoreConfidence = n >= solidSessions ? .solid : .building

            results.append(ActivityCost(sport: sport, delta: delta,
                                        meanNextMorning: meanNextMorning,
                                        baselineMean: baselineMean,
                                        daysToBaseline: daysToBaseline,
                                        n: n, confidence: confidence))
        }

        return rank(results)
    }

    // MARK: - Bounce-back trajectory

    /// Smallest k in 1...maxLookahead where the averaged forward trajectory is within `tolerance`
    /// of `baselineMean`; nil if never or no data at that horizon.
    static func forwardDaysToBaseline(taggedDays: Set<String>,
                                      recoveryByDay: [String: Double],
                                      baselineMean: Double) -> Int? {
        let target = baselineMean - tolerance
        for k in 1...maxLookahead {
            var vals: [Double] = []
            for day in taggedDays {
                guard let dk = CorrelationEngine.shiftDay(day, by: k),
                      let v = recoveryByDay[dk] else { continue }
                vals.append(v)
            }
            guard !vals.isEmpty else { continue }
            if mean(vals) >= target { return k }
        }
        return nil
    }

    // MARK: - Ranking

    /// Stable rank: |delta| desc, .solid before .building, then sport name.
    static func rank(_ items: [ActivityCost]) -> [ActivityCost] {
        items.sorted { a, b in
            let da = abs(a.delta), db = abs(b.delta)
            if da != db { return da > db }
            let ra = confidenceRank(a.confidence), rb = confidenceRank(b.confidence)
            if ra != rb { return ra > rb }   // higher rank (solid) first
            return a.sport < b.sport
        }
    }

    /// Ordinal so .solid sorts ahead of .building.
    static func confidenceRank(_ c: ScoreConfidence) -> Int {
        switch c {
        case .solid: return 2
        case .building: return 1
        case .calibrating: return 0
        }
    }

    // MARK: - Stats (self-contained so the Kotlin mirror is line-for-line)

    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Round half away from zero (non-negative magnitudes in `sentence()`).
    static func roundToInt(_ x: Double) -> Int {
        Int(x.rounded())
    }
}
