import Foundation

// VitalityEngine: a transparent 0-100 "Vitality" wellness score plus an optional "Body Age in years".
// Independent implementation of the published method behind WHOOP's Healthspan (not medical advice; a
// wellness comparison, never a clinical biological age): each wearable-measurable input maps to its
// published ALL-CAUSE-MORTALITY hazard ratio vs a population reference; log-hazards are summed with an
// overlap correction (inputs are correlated) and converted to a "years of aging" offset via the Gompertz
// doubling time (mortality doubles every ~8 years).
//
// Body Age = chronological age + delta; an average person reads at their own age. Shown with a +/- band
// and a "wellness trend, not a biological/clinical age" disclaimer, gated on a minimum number of inputs.
// Hazard ratios come from large cohorts / meta-analyses (UK Biobank, FRIEND, step-mortality, sleep-
// regularity and HRV cohorts), deliberately CONSERVATIVE and clamped.
public enum VitalityEngine {

    // Gompertz: mortality doubling time ~8 years, so ln(hazard) per year of age = ln(2)/8.
    static let lnHazardPerYear = 0.6931471805599453 / 8.0   // ≈ 0.0866
    /// Correlated inputs (fitness, RHR, activity) would multiply the same signal; 0.75 is a gentle shrink of the log-hazard sum.
    static let overlapShrink = 0.75
    /// Body Age is clamped to a sane band; Vitality maps delta-age linearly around 50 (= "at your age").
    static let minBodyAge = 20.0, maxBodyAge = 90.0
    static let vitalityPerYear = 2.5   // each year younger than your age = +2.5 Vitality points

    /// The wearable inputs Vitality reads; all optional (the score needs at least `minFactors`).
    public struct Inputs: Equatable, Sendable {
        public var chronoAge: Double
        public var restingHR: Double?          // bpm
        public var vo2max: Double?             // ml/kg/min (e.g. from FitnessAgeEngine)
        public var expectedVO2max: Double?     // age/sex-expected ml/kg/min (the reference for vo2max)
        public var sleepHours: Double?         // mean nightly sleep
        public var sleepConsistency: Double?   // 0–1 regularity (1 = perfectly regular)
        public var rmssd: Double?              // ms, nocturnal HRV
        public var rmssdNorm: Double?          // age/sex-normative RMSSD (the reference)
        public var steps: Double?              // mean daily steps
        public init(chronoAge: Double, restingHR: Double? = nil, vo2max: Double? = nil,
                    expectedVO2max: Double? = nil, sleepHours: Double? = nil,
                    sleepConsistency: Double? = nil, rmssd: Double? = nil,
                    rmssdNorm: Double? = nil, steps: Double? = nil) {
            self.chronoAge = chronoAge; self.restingHR = restingHR; self.vo2max = vo2max
            self.expectedVO2max = expectedVO2max; self.sleepHours = sleepHours
            self.sleepConsistency = sleepConsistency; self.rmssd = rmssd
            self.rmssdNorm = rmssdNorm; self.steps = steps
        }
    }

    /// One factor's signed log-hazard vs the population reference (positive ages you, negative protective).
    public struct Contribution: Equatable, Sendable {
        public let key: String
        public let label: String
        public let lnHazard: Double
        public init(key: String, label: String, lnHazard: Double) {
            self.key = key; self.label = label; self.lnHazard = lnHazard
        }
    }

    public struct Result: Equatable, Sendable {
        public let vitality: Double        // 0–100 (50 = typical for your age)
        public let bodyAge: Double         // years, clamped
        public let chronoAge: Double
        public let deltaYears: Double      // chronoAge − bodyAge (positive = younger than your age)
        public let bandYears: Double
        public let contributions: [Contribution]   // for the "what's driving this" breakdown
        public let factorsUsed: Int
        public init(vitality: Double, bodyAge: Double, chronoAge: Double, deltaYears: Double,
                    bandYears: Double, contributions: [Contribution], factorsUsed: Int) {
            self.vitality = vitality; self.bodyAge = bodyAge; self.chronoAge = chronoAge
            self.deltaYears = deltaYears; self.bandYears = bandYears
            self.contributions = contributions; self.factorsUsed = factorsUsed
        }
    }

    /// Minimum distinct factors before showing a number (honesty gate).
    public static let minFactors = 3
    public static let bandYears = 5.0

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    /// Nocturnal RMSSD ~50th-percentile by age (ms), piecewise-linear between decade anchors (WHOOP-window
    /// norms, never mixed with daytime clinical norms). A person at the age norm contributes 0.
    public static func rmssdNorm(forAge age: Double) -> Double {
        let anchors: [(Double, Double)] = [(20, 47), (30, 40), (40, 33), (50, 29), (60, 25), (70, 22), (80, 20)]
        if age <= anchors[0].0 { return anchors[0].1 }
        if age >= anchors[anchors.count - 1].0 { return anchors[anchors.count - 1].1 }
        for i in 1..<anchors.count where age <= anchors[i].0 {
            let (a0, v0) = anchors[i - 1]; let (a1, v1) = anchors[i]
            return v0 + (v1 - v0) * (age - a0) / (a1 - a0)
        }
        return anchors[anchors.count - 1].1
    }

    /// Sleep regularity (0-1): 1 minus the coefficient of variation of nightly durations, clamped; a rough
    /// proxy for the Sleep Regularity Index. Nil under 3 nights.
    public static func sleepConsistency(nightlyHours: [Double]) -> Double? {
        let xs = nightlyHours.filter { $0 > 0 }
        guard xs.count >= 3 else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        guard mean > 0 else { return nil }
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        let cv = variance.squareRoot() / mean
        return clamp(1 - cv, 0, 1)
    }

    /// Per-factor log-hazard contributions present in `inputs`, each vs a population reference (an average
    /// person nets ~0). Published per-unit hazard ratios (conservative, clamped):
    ///   - Resting HR: +~10.5% all-cause mortality per +10 bpm (UK Biobank / meta-analyses); ref 65.
    ///   - VO2max: ~14% per MET (3.5 ml/kg/min) vs the age/sex-expected value (FRIEND).
    ///   - Sleep duration: U-shaped, optimum ~7.5 h; only deviation beyond +/-0.5 h adds hazard (~12%/h).
    ///   - Sleep regularity: most- vs least-regular HR 0.70 (UK Biobank SRI); ref 0.75 of the 0-1 range.
    ///   - HRV (RMSSD): ~16% per relative SD below the age norm.
    ///   - Steps: ~12% per 1,000 steps/day up to ~7k, diminishing to ~11k (pooled meta-analysis).
    public static func contributions(_ inputs: Inputs) -> [Contribution] {
        var out: [Contribution] = []
        if let rhr = inputs.restingHR {
            out.append(Contribution(key: "rhr", label: "Resting heart rate",
                                    lnHazard: ((rhr - 65) / 10) * 0.100))
        }
        if let vo2 = inputs.vo2max, let exp = inputs.expectedVO2max, exp > 0 {
            // (expected - vo2): negative when fitter than expected, i.e. protective.
            out.append(Contribution(key: "vo2max", label: "Cardio fitness",
                                    lnHazard: clamp((exp - vo2) / 3.5, -4, 4) * 0.130))
        }
        if let sh = inputs.sleepHours {
            let dev = max(0, abs(sh - 7.5) - 0.5)   // only deviation > ±0.5 h is a risk; optimum is neutral
            out.append(Contribution(key: "sleep", label: "Sleep duration",
                                    lnHazard: clamp(dev, 0, 3) * 0.110))
        }
        if let c = inputs.sleepConsistency {
            out.append(Contribution(key: "consistency", label: "Sleep regularity",
                                    lnHazard: (0.75 - clamp(c, 0, 1)) * 0.450))
        }
        if let h = inputs.rmssd, let norm = inputs.rmssdNorm, norm > 0 {
            out.append(Contribution(key: "hrv", label: "Heart-rate variability",
                                    lnHazard: clamp((norm - h) / norm, -1, 1) * 0.160))
        }
        if let s = inputs.steps {
            // Below ~7k each -1,000 steps adds hazard; protection caps near 11k.
            let deficit = (7000 - clamp(s, 0, 11000)) / 1000
            out.append(Contribution(key: "steps", label: "Daily steps",
                                    lnHazard: clamp(deficit, -4, 4) * 0.064))
        }
        return out
    }

    /// Full Vitality + Body Age; nil until at least `minFactors` inputs are present.
    public static func compute(_ inputs: Inputs) -> Result? {
        guard inputs.chronoAge > 0 else { return nil }
        let contribs = contributions(inputs)
        guard contribs.count >= minFactors else { return nil }
        let sumLn = contribs.reduce(0) { $0 + $1.lnHazard } * overlapShrink
        let deltaAge = sumLn / lnHazardPerYear              // +ve = ages you
        let bodyAge = clamp(inputs.chronoAge + deltaAge, minBodyAge, maxBodyAge)
        let delta = inputs.chronoAge - bodyAge              // +ve = younger than your age
        let vitality = clamp(50 + delta * vitalityPerYear, 0, 100)
        return Result(vitality: vitality, bodyAge: bodyAge, chronoAge: inputs.chronoAge,
                      deltaYears: delta, bandYears: bandYears, contributions: contribs,
                      factorsUsed: contribs.count)
    }
}
