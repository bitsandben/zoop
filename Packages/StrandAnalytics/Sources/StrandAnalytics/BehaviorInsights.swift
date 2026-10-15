import Foundation

// Does a logged behavior move an outcome? Pure and deterministic. Splits days with the behavior
// logged from days without and compares the outcome (Recovery, HRV, sleep performance). Reports group
// means, delta and pctChange, Cohen's d with the pooled SD, and an approximate two-sided p-value from
// Welch's t-test (Welch-Satterthwaite df, normal-approximation tail: deterministic, slightly
// understates p for small samples). `significant` needs p < 0.05 and min group size >= 5. Direction is
// the sign of delta / cohensD. `rank` orders by |cohensD| with significant effects first.

/// The measured effect of one behavior on one outcome metric.
public struct BehaviorEffect: Equatable, Sendable {
    /// The behavior label (e.g. "Alcohol").
    public let behavior: String
    /// The outcome metric label (e.g. "Recovery").
    public let outcome: String
    /// Mean outcome on days the behavior was logged.
    public let meanWith: Double
    /// Mean outcome on days it was not.
    public let meanWithout: Double
    /// meanWith - meanWithout (signed).
    public let delta: Double
    /// Percent change of meanWith relative to meanWithout; nil when meanWithout is 0.
    public let pctChange: Double?
    /// Behavior-present days with an outcome value.
    public let nWith: Int
    /// Behavior-absent days with an outcome value.
    public let nWithout: Int
    /// Cohen's d with the pooled SD (sign matches delta).
    public let cohensD: Double
    /// Two-sided p-value (Welch t-test, normal approximation).
    public let pApprox: Double
    /// pApprox < 0.05 and min(nWith, nWithout) >= 5.
    public let significant: Bool

    public init(behavior: String, outcome: String, meanWith: Double, meanWithout: Double,
                delta: Double, pctChange: Double?, nWith: Int, nWithout: Int,
                cohensD: Double, pApprox: Double, significant: Bool) {
        self.behavior = behavior
        self.outcome = outcome
        self.meanWith = meanWith
        self.meanWithout = meanWithout
        self.delta = delta
        self.pctChange = pctChange
        self.nWith = nWith
        self.nWithout = nWithout
        self.cohensD = cohensD
        self.pApprox = pApprox
        self.significant = significant
    }
}

public enum BehaviorInsights {

    /// Minimum size of each group for an effect to be flagged significant.
    public static let minGroupForSignificance: Int = 5
    /// Significance threshold on the approximate p-value.
    public static let alpha: Double = 0.05

    // MARK: - Single behavior effect

    /// Effect of `behavior` on `outcome`. "With" is day in `behaviorDays`; "without" is day in
    /// `controlDays`. Days in neither are dropped: counting every unlogged day as a control measured a
    /// behaviour logged Yes on 20 days against 100 days the user never answered. The journal already
    /// distinguishes the states (a No writes `answeredYes = false`; only Clear deletes the row). Expect
    /// fewer findings: unlogged days inflated nWithout and the min-group gate. With no No days there is
    /// no comparison to make.
    /// Returns nil unless both groups are non-empty and the total is at least 3.
    public static func effect(behaviorDays: Set<String>,
                              controlDays: Set<String>,
                              outcomeByDay: [String: Double],
                              behavior: String,
                              outcome: String) -> BehaviorEffect? {
        var withVals: [Double] = []
        var withoutVals: [Double] = []
        for (day, value) in outcomeByDay {
            if behaviorDays.contains(day) { withVals.append(value) }
            else if controlDays.contains(day) { withoutVals.append(value) }
            // Neither: not logged that day, so not a control. A day in both counts as "with"; callers merge imported
            // and native logs first so one question cannot hold two answers for a day.
        }

        let n1 = withVals.count
        let n2 = withoutVals.count
        // Need both groups and enough points for a variance estimate.
        guard n1 >= 1, n2 >= 1, n1 + n2 >= 3 else { return nil }

        let m1 = withVals.reduce(0, +) / Double(n1)
        let m2 = withoutVals.reduce(0, +) / Double(n2)
        let delta = m1 - m2

        let pct: Double? = m2 != 0 ? (delta / abs(m2) * 100.0) : nil

        let v1 = sampleVariance(withVals, mean: m1)   // ddof=1; 0 when n==1
        let v2 = sampleVariance(withoutVals, mean: m2)

        let d = cohensD(m1: m1, m2: m2, n1: n1, v1: v1, n2: n2, v2: v2)
        let p = welchP(m1: m1, v1: v1, n1: n1, m2: m2, v2: v2, n2: n2)

        let sig = p < alpha && Swift.min(n1, n2) >= minGroupForSignificance

        return BehaviorEffect(behavior: behavior, outcome: outcome,
                              meanWith: m1, meanWithout: m2, delta: delta,
                              pctChange: pct, nWith: n1, nWithout: n2,
                              cohensD: d, pApprox: p, significant: sig)
    }

    // MARK: - Ranking

    /// Effects for every behavior against one outcome, sorted by |cohensD| descending with significant
    /// ones first; behaviors without a computable effect are dropped.
    public static func rank(behaviors: [String: Set<String>],
                            controls: [String: Set<String>],
                            outcomeByDay: [String: Double],
                            outcome: String) -> [BehaviorEffect] {
        var effects: [BehaviorEffect] = []
        for (name, days) in behaviors {
            // A behaviour absent from `controls` has no controls and yields nothing: fails closed rather than
            // measuring against every day the user never opened the journal.
            if let e = effect(behaviorDays: days, controlDays: controls[name] ?? [],
                              outcomeByDay: outcomeByDay,
                              behavior: name, outcome: outcome) {
                effects.append(e)
            }
        }
        return effects.sorted { a, b in
            if a.significant != b.significant { return a.significant }  // significant first
            let la = abs(a.cohensD), lb = abs(b.cohensD)
            if la != lb { return la > lb }                              // bigger effect first
            return a.behavior < b.behavior                             // stable tiebreak
        }
    }

    // MARK: - Sentence

    /// Plain-English sentence for the UI, e.g. "On days you logged 'Alcohol', Recovery was 12% lower
    /// (avg 61 vs 69, n=140 vs 498)." Falls back to absolute units when pctChange is nil.
    public static func sentence(_ e: BehaviorEffect) -> String {
        let directionWord: String
        if e.delta > 0 { directionWord = "higher" }
        else if e.delta < 0 { directionWord = "lower" }
        else { directionWord = "unchanged" }

        let magnitude: String
        if e.delta == 0 {
            magnitude = "no different"
        } else if let pct = e.pctChange {
            magnitude = "\(roundedInt(abs(pct)))% \(directionWord)"
        } else {
            magnitude = "\(round1(abs(e.delta))) \(directionWord)"
        }

        let avgWith = roundedInt(e.meanWith)
        let avgWithout = roundedInt(e.meanWithout)

        return "On days you logged ‘\(e.behavior)’, \(e.outcome) was \(magnitude) "
            + "(avg \(avgWith) vs \(avgWithout), n=\(e.nWith) vs \(e.nWithout))."
    }

    // MARK: - Statistics helpers

    /// Sample variance (ddof = 1); 0 for fewer than 2 values.
    static func sampleVariance(_ values: [Double], mean: Double) -> Double {
        let n = values.count
        guard n >= 2 else { return 0 }
        var ss = 0.0
        for v in values { let d = v - mean; ss += d * d }
        return ss / Double(n - 1)
    }

    /// Cohen's d with the pooled SD; 0 when the pooled SD is 0 (no spread to scale), whether or not the means differ.
    static func cohensD(m1: Double, m2: Double, n1: Int, v1: Double,
                        n2: Int, v2: Double) -> Double {
        let df = n1 + n2 - 2
        guard df > 0 else { return 0 }
        let pooledVar = (Double(n1 - 1) * v1 + Double(n2 - 1) * v2) / Double(df)
        let sp = pooledVar.squareRoot()
        guard sp > 0 else { return 0 }
        return (m1 - m2) / sp
    }

    /// Two-sided Welch t-test p-value with a normal-approximation tail; 1.0 when neither group has a usable standard error.
    static func welchP(m1: Double, v1: Double, n1: Int,
                       m2: Double, v2: Double, n2: Int) -> Double {
        let se2 = v1 / Double(n1) + v2 / Double(n2)
        guard se2 > 0 else {
            // No spread anywhere: identical means give p=1, differing means p~0.
            return m1 == m2 ? 1.0 : 0.0
        }
        let t = (m1 - m2) / se2.squareRoot()
        return 2.0 * (1.0 - CorrelationEngine.normalCDF(abs(t)))
    }

    // MARK: - Formatting helpers

    /// Round to the nearest integer, as Int.
    static func roundedInt(_ x: Double) -> Int { Int((x).rounded()) }

    /// Round to one decimal place.
    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
