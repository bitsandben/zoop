import Foundation

// FitnessAgeEngine.swift — on-device "Fitness Age": a weighted, multi-marker age estimate in the style
// of Bevel's Biological Age.
//
// WHAT BEVEL DOES (as far as it is public): Bevel's Biological Age is a weekly number (it updates on
// Mondays) built from "a mix of physiological, lifestyle and blood biomarker data", shown with a
// confidence level and the factors moving it (resting-HR baseline, HRV baseline, weight, body fat,
// VO₂max, …). Bevel does not publish its formula or weights. Sources:
//   https://gadgetsandwearables.com/2026/05/16/bevel-3/ (Bevel 3.0 review: weekly, factors, confidence)
//   https://athletechnews.com/bevel-launches-health-companion/ (biomarkers: VO₂, RHR, HRV, weight, body fat)
// So this is NOT Bevel's model; it is an independent estimate with the same SHAPE: several markers,
// each turned into "years older/younger than a typical peer of your age and sex", then blended with
// fixed weights where VO₂max dominates (the strongest single predictor of all-cause mortality,
// Kodama 2009 JAMA 301(19):2024; Mandsager 2018 JAMA Netw Open 1(6):e183605).
//
// PER-FACTOR YEARS (each bounded, positive = older):
//   • VO₂max — the HUNT "fitness age" idea (Nes 2013, Med Sci Sports Exerc 45(3):542): the age at
//     which a typical peer has YOUR VO₂max, minus your age. The norm curve must be on the same scale as
//     the VO₂max it is compared with, so a MEASURED value (Apple Health / Oura, lab-like) is read against
//     the FRIEND registry 50th percentiles (Kaminsky 2015, Mayo Clin Proc 90(11):1515) and the Nes 2011
//     waist-based ESTIMATE against the HUNT decade means it was fitted on (Loe 2013, PLoS ONE
//     8(5):e64319, approximate). The resting-HR-only Uth estimate is NOT used here: it is a function of
//     resting HR alone, which already has its own factor. Bounded ±20.
//   • Resting HR — the Nes 2011 resting-HR coefficient over its age coefficient (≈0.52 yr/bpm men,
//     0.46 women) against a 65 bpm reference. Bounded ±15.
//   • HRV — nightly RMSSD against the age norm (`VitalityEngine.rmssdNorm`), on the log scale where
//     between-person spread is ≈0.45; one spread ≈ 6 years. Bounded ±10.
//   • Activity — the HUNT PA-index (0–15) against 5, at the Nes activity/age coefficient ratio
//     (≈0.76 yr per point). Bounded ±8.
//   • Body — body fat against a sex reference (20 % men / 28 % women, 0.35 yr per point) when measured,
//     else BMI outside 18.5–25 (0.8 yr per unit). Bounded −4…+8.
//   • Sleep regularity — night-to-night duration regularity (0–1) against 0.8. Bounded ±3.
//
// BLEND: fitness age = age + Σ wᵢ·yearsᵢ / Σ wᵢ over the factors present, with weights VO₂max 0.40,
// resting HR 0.20, HRV 0.15, activity 0.10, body 0.10, sleep 0.05. Missing factors drop out and the
// rest are renormalised, so the number works with resting HR alone. The result is bounded to the
// chronological age ±15 (and 18…90). Inputs are 30-day medians, and the value is written once a week,
// so it moves slowly. It is an estimate for tracking direction, not a medical or biological measurement.
public enum FitnessAgeEngine {

    // MARK: - Nes 2011 waist-circumference coefficients (JAHA PMC7428991, confirmed vs CERG)
    // VO₂max = intercept − ageC·age + paiC·PA − wcC·waist − rhrC·RHR
    static let menIntercept = 100.27, menAge = 0.296, menWC = 0.369, menRHR = 0.155, menPAI = 0.226
    static let womenIntercept = 74.74, womenAge = 0.247, womenWC = 0.259, womenRHR = 0.114, womenPAI = 0.198
    public static let seeMen = 5.70, seeWomen = 5.14

    // MARK: - Normative reference point (the "average peer" the Fitness Age compares against)
    /// Population-reference resting HR (bpm): an average healthy adult. At it the resting-HR factor adds 0.
    public static let restingHRReference = 65.0
    /// Population-reference PA-index (0–15): ≈ "moderately active, a few sessions a week"; adds 0.
    public static let paiReference = 5.0

    /// Displayed uncertainty band (years) — a presentation constant for the estimate's honesty line.
    public static let displayBandYears = 5.0
    /// Absolute bounds of a stored fitness age.
    public static let minAge = 18.0, maxAge = 90.0
    /// The furthest a fitness age may sit from the chronological age.
    public static let maxOffsetYears = 15.0

    private static func isFemale(_ sex: String) -> Bool { sex.lowercased() == "female" }

    /// Coefficient tuple for the user's sex (intercept, ageC, wcC, rhrC, paiC). Non-binary uses men's.
    private static func coeffs(_ sex: String) -> (Double, Double, Double, Double, Double) {
        isFemale(sex)
            ? (womenIntercept, womenAge, womenWC, womenRHR, womenPAI)
            : (menIntercept, menAge, menWC, menRHR, menPAI)
    }

    /// Body-mass index from metric height/weight (feeds the body factor when no body fat is measured).
    public static func bmi(weightKg: Double, heightCm: Double) -> Double {
        let m = heightCm / 100.0
        guard m > 0 else { return 0 }
        return weightKg / (m * m)
    }

    /// Nes 2011 waist-variant VO₂max (ml/kg/min). Optional display metric — needs a waist measurement.
    public static func estimateVO2max(age: Double, sex: String, waistCm: Double,
                                      restingHR: Double, paIndex: Double) -> Double {
        let (intercept, ageC, wcC, rhrC, paiC) = coeffs(sex)
        return intercept - ageC*age + paiC*paIndex - wcC*waistCm - rhrC*restingHR
    }

    /// Reconstruct the HUNT PA-index (0–15 = frequency×intensity×duration) from measured weekly
    /// aggregates. Bucket edges mirror the HUNT1 PA-Q response options (Kurtze 2008):
    ///   frequency ∈ {0.0, 0.5, 1.0, 2.5, 5.0}  ← active days in the last 7
    ///   intensity ∈ {1, 2, 3}                  ← share of active time at high intensity (HR zone 4–5)
    ///   duration  ∈ {0.10, 0.38, 0.75, 1.0}    ← average active minutes per active day
    public static func physicalActivityIndex(activeDaysPerWeek: Int,
                                             avgActiveMinutesPerDay: Double,
                                             highIntensityFraction: Double) -> Double {
        let frequency: Double
        switch activeDaysPerWeek {
        case ..<1: frequency = 0.0
        case 1:    frequency = 0.5
        case 2:    frequency = 1.0
        case 3...4: frequency = 2.5
        default:   frequency = 5.0          // 5+ days ≈ "almost every day"
        }
        let intensity: Double
        switch highIntensityFraction {
        case ..<0.15: intensity = 1.0       // easy, no real sweat
        case ..<0.5:  intensity = 2.0       // sweaty / breathless
        default:      intensity = 3.0       // near exhaustion
        }
        let duration: Double
        switch avgActiveMinutesPerDay {
        case ..<15:  duration = 0.10
        case ..<30:  duration = 0.38
        case ..<60:  duration = 0.75
        default:     duration = 1.0
        }
        if frequency == 0 { return 0 }
        return frequency * intensity * duration
    }

    /// PA-index (0–15) from Zoop's measured weekly load — the UNIVERSAL path the orchestrator uses
    /// (works on any device, since `strain` is computed from HR alone; HR-zone minutes only exist for
    /// CSV-importers). `strain` (0–100, TRIMP-based) already integrates intensity × duration, so we map
    /// the mean active-day strain straight to the HUNT intensity×duration PRODUCT (0–3) and multiply by
    /// the frequency factor — deliberately NOT re-deriving intensity and duration separately, which
    /// would double-count the same HR load. Calibrated so the reference peer (≈4 active days, mean
    /// strain ≈60) lands near PA-index 5.
    public static func physicalActivityIndexFromStrain(activeDaysPerWeek: Int,
                                                       meanActiveStrain: Double) -> Double {
        let frequency: Double
        switch activeDaysPerWeek {
        case ..<1: frequency = 0.0
        case 1:    frequency = 0.5
        case 2:    frequency = 1.0
        case 3...4: frequency = 2.5
        default:   frequency = 5.0
        }
        if frequency == 0 { return 0 }
        let intensityDuration = min(3.0, max(0.0, meanActiveStrain / 30.0))   // strain 30→1, 60→2, 90→3
        return frequency * intensityDuration
    }

}

// MARK: - Multi-marker model

/// One marker that moves the fitness age. Raw values double as the stored series suffixes.
public enum FitnessAgeFactor: String, CaseIterable, Sendable {
    case vo2max, restingHR = "rhr", hrv, activity, body, sleep

    /// Blend weight (see the file header). VO₂max dominates.
    public var weight: Double {
        switch self {
        case .vo2max: return 0.40
        case .restingHR: return 0.20
        case .hrv: return 0.15
        case .activity: return 0.10
        case .body: return 0.10
        case .sleep: return 0.05
        }
    }

    /// Series key of the years this factor added to a stored fitness age.
    public var contributionKey: String { "fitness_age_c_" + rawValue }
    /// Series key of the input value this factor was scored on.
    public var inputKey: String { "fitness_age_in_" + rawValue }
}

/// Where a VO₂max number came from, which decides the norm it is read against.
public enum FitnessVO2Source: String, Sendable {
    /// A device or lab measurement (Apple Health, Oura): FRIEND registry norms.
    case measured
    /// The Nes 2011 waist-based estimate: the HUNT norms it was fitted on.
    case nesEstimate
}

/// Everything the fitness age can use. Only `chronoAge`, `sex` and `restingHR` are required.
public struct FitnessAgeInputs: Equatable, Sendable {
    public var chronoAge: Double
    public var sex: String
    /// 30-day resting-HR baseline (bpm).
    public var restingHR: Double
    public var vo2max: Double?
    public var vo2Source: FitnessVO2Source
    /// 30-day nightly RMSSD baseline (ms).
    public var rmssd: Double?
    /// HUNT PA-index, 0–15.
    public var activityIndex: Double?
    public var bmi: Double?
    public var bodyFatPct: Double?
    /// Night-to-night sleep regularity, 0–1.
    public var sleepConsistency: Double?

    public init(chronoAge: Double, sex: String, restingHR: Double,
                vo2max: Double? = nil, vo2Source: FitnessVO2Source = .measured,
                rmssd: Double? = nil, activityIndex: Double? = nil,
                bmi: Double? = nil, bodyFatPct: Double? = nil, sleepConsistency: Double? = nil) {
        self.chronoAge = chronoAge; self.sex = sex; self.restingHR = restingHR
        self.vo2max = vo2max; self.vo2Source = vo2Source; self.rmssd = rmssd
        self.activityIndex = activityIndex; self.bmi = bmi; self.bodyFatPct = bodyFatPct
        self.sleepConsistency = sleepConsistency
    }
}

extension FitnessAgeEngine {

    /// FRIEND registry 50th-percentile VO₂max (treadmill CPET) at decade midpoints (Kaminsky 2015).
    static let friendMen: [(Double, Double)] = [(25, 48.0), (35, 42.4), (45, 37.8), (55, 32.6), (65, 28.2), (75, 24.4)]
    static let friendWomen: [(Double, Double)] = [(25, 37.6), (35, 30.9), (45, 27.9), (55, 24.2), (65, 20.7), (75, 18.3)]
    /// HUNT Fitness Study mean VO₂peak at decade midpoints (Loe 2013, approximate).
    static let huntMen: [(Double, Double)] = [(25, 54.4), (35, 49.0), (45, 47.7), (55, 42.6), (65, 39.2), (75, 35.0)]
    static let huntWomen: [(Double, Double)] = [(25, 43.0), (35, 40.0), (45, 38.4), (55, 34.8), (65, 31.4), (75, 28.9)]

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    private static func normTable(sex: String, source: FitnessVO2Source) -> [(Double, Double)] {
        let female = sex.lowercased() == "female"
        switch source {
        case .measured: return female ? friendWomen : friendMen
        case .nesEstimate: return female ? huntWomen : huntMen
        }
    }

    /// Typical VO₂max for an age on the given scale (piecewise linear, extrapolated past the ends).
    public static func vo2Norm(age: Double, sex: String, source: FitnessVO2Source) -> Double {
        let t = normTable(sex: sex, source: source)
        let i: Int
        if age <= t[0].0 { i = 1 } else if age >= t[t.count - 1].0 { i = t.count - 1 }
        else { i = t.indices.first { t[$0].0 >= age } ?? t.count - 1 }
        let (a0, v0) = t[i - 1], (a1, v1) = t[i]
        return v0 + (v1 - v0) * (age - a0) / (a1 - a0)
    }

    /// The age at which a typical peer has this VO₂max (inverse of `vo2Norm`, extrapolated).
    public static func vo2Age(_ vo2: Double, sex: String, source: FitnessVO2Source) -> Double {
        let t = normTable(sex: sex, source: source)
        // Norms fall with age, so the segments are walked by value.
        let i: Int
        if vo2 >= t[0].1 { i = 1 } else if vo2 <= t[t.count - 1].1 { i = t.count - 1 }
        else { i = t.indices.first { t[$0].1 <= vo2 } ?? t.count - 1 }
        let (a0, v0) = t[i - 1], (a1, v1) = t[i]
        return a0 + (vo2 - v0) * (a1 - a0) / (v1 - v0)
    }

    /// Years one factor alone would move the age (positive = older), before weighting. nil when the
    /// input is missing.
    public static func factorYears(_ factor: FitnessAgeFactor, _ x: FitnessAgeInputs) -> Double? {
        let female = x.sex.lowercased() == "female"
        switch factor {
        case .vo2max:
            guard let v = x.vo2max, v > 0 else { return nil }
            return clamp(vo2Age(v, sex: x.sex, source: x.vo2Source) - x.chronoAge, -20, 20)
        case .restingHR:
            guard x.restingHR > 0 else { return nil }
            let perBpm = female ? womenRHR / womenAge : menRHR / menAge
            return clamp(perBpm * (x.restingHR - restingHRReference), -15, 15)
        case .hrv:
            guard let r = x.rmssd, r > 0 else { return nil }
            let z = log(r / VitalityEngine.rmssdNorm(forAge: x.chronoAge)) / 0.45
            return clamp(-6 * z, -10, 10)
        case .activity:
            guard let p = x.activityIndex else { return nil }
            let perPoint = female ? womenPAI / womenAge : menPAI / menAge
            return clamp(-perPoint * (p - paiReference), -8, 8)
        case .body:
            if let bf = x.bodyFatPct, bf > 0 {
                return clamp(0.35 * (bf - (female ? 28.0 : 20.0)), -4, 8)
            }
            guard let b = x.bmi, b > 0 else { return nil }
            if b > 25 { return clamp(0.8 * (b - 25), 0, 8) }
            if b < 18.5 { return clamp(0.8 * (18.5 - b), 0, 8) }
            return 0
        case .sleep:
            guard let c = x.sleepConsistency else { return nil }
            return clamp((0.8 - c) * 15, -3, 3)
        }
    }

    /// The fitness age from whatever inputs are present. nil without an age or resting HR.
    public static func compute(_ x: FitnessAgeInputs, lowerConfidence: Bool = false) -> FitnessAgeResult? {
        guard x.chronoAge > 0, x.restingHR > 0 else { return nil }
        var present: [(FitnessAgeFactor, Double)] = []
        for f in FitnessAgeFactor.allCases {
            if let y = factorYears(f, x) { present.append((f, y)) }
        }
        let totalWeight = present.reduce(0) { $0 + $1.0.weight }
        var contributions: [FitnessAgeFactor: Double] = [:]
        for (f, y) in present { contributions[f] = f.weight / totalWeight * y }
        let offset = contributions.values.reduce(0, +)
        let lo = max(minAge, x.chronoAge - maxOffsetYears), hi = min(maxAge, x.chronoAge + maxOffsetYears)
        let raw = x.chronoAge + offset
        let fa = (clamp(raw, lo, hi) * 10).rounded() / 10
        let nb = x.sex.lowercased() != "male" && x.sex.lowercased() != "female"
        return FitnessAgeResult(
            vo2max: x.vo2max, fitnessAge: fa, chronoAge: x.chronoAge, deltaYears: x.chronoAge - fa,
            bandYears: displayBandYears, lowerConfidence: lowerConfidence || nb,
            contributions: contributions, bounded: raw < lo || raw > hi)
    }
}

// MARK: - Readiness checklist
//
// Transparency over a black-box number: show the user exactly which inputs we have, grouped by what
// each one unlocks, and a single confidence verdict. Height/weight feed the body factor; the waist only
// unlocks the Nes VO₂max estimate. The gate is age, sex, and resting-HR coverage over the last 7 days.

public enum FitnessReadinessStatus: String, Sendable { case satisfied, partial, missing }

/// What a given input affects — so the checklist can be honest about its impact.
public enum FitnessReadinessRole: String, Sendable {
    case drivesAge          // required for / sharpens the headline Fitness Age
    case unlocksVO2max      // only powers the separate VO₂max estimate
}

public struct FitnessReadinessItem: Equatable, Sendable {
    public let key: String
    public let label: String
    public let status: FitnessReadinessStatus
    public let required: Bool        // true → the number can't be computed without it
    public let role: FitnessReadinessRole
    public let detail: String        // short hint, e.g. "4 of last 7 nights"
    public init(key: String, label: String, status: FitnessReadinessStatus,
                required: Bool, role: FitnessReadinessRole, detail: String) {
        self.key = key; self.label = label; self.status = status
        self.required = required; self.role = role; self.detail = detail
    }
}

public enum FitnessAgeConfidence: String, Sendable {
    case ready      // everything we need, good coverage
    case estimate   // computes, but partial coverage — a softer claim
    case notReady   // can't compute yet (missing a required input)
}

public struct FitnessAgeReadiness: Equatable, Sendable {
    public let items: [FitnessReadinessItem]
    public let confidence: FitnessAgeConfidence
    public var canCompute: Bool { confidence != .notReady }
    public init(items: [FitnessReadinessItem], confidence: FitnessAgeConfidence) {
        self.items = items; self.confidence = confidence
    }
}

extension FitnessAgeEngine {
    /// Minimum nights of resting-HR before the headline can be computed at all.
    public static let minCoverageDays = 4
    /// Coverage at/above which an input reads as fully satisfied (a "confident" week).
    public static let goodCoverageDays = 6

    /// Nights of resting-HR still needed before the headline can compute AT ALL — the countdown the
    /// not-ready card shows ("N more nights of wear…"). 0 once `minCoverageDays` is met. Assumes continued
    /// nightly wear (a skipped night just doesn't advance the count). Shared with the Android engine so both
    /// platforms show the same number.
    public static func nightsUntilReady(rhrDays: Int) -> Int { max(0, minCoverageDays - rhrDays) }

    private static func coverageStatus(_ days: Int, floor: Int) -> FitnessReadinessStatus {
        if days >= goodCoverageDays { return .satisfied }
        if days >= floor || days > 0 { return .partial }
        return .missing
    }

    /// Build the readiness checklist + overall confidence from the inputs we have. The orchestrator
    /// passes profile-completeness flags and the 7-day coverage counts.
    public static func assessReadiness(hasAge: Bool, hasSex: Bool,
                                       rhrDays: Int, activityDays: Int,
                                       hasHeightWeight: Bool, hasWaist: Bool) -> FitnessAgeReadiness {
        let items: [FitnessReadinessItem] = [
            FitnessReadinessItem(key: "age", label: "Your age",
                status: hasAge ? .satisfied : .missing, required: true, role: .drivesAge,
                detail: hasAge ? "Set" : "Add it in Settings"),
            FitnessReadinessItem(key: "sex", label: "Biological sex",
                status: hasSex ? .satisfied : .missing, required: true, role: .drivesAge,
                detail: hasSex ? "Set" : "Add it in Settings"),
            FitnessReadinessItem(key: "rhr", label: "Resting heart rate",
                status: coverageStatus(rhrDays, floor: minCoverageDays), required: true, role: .drivesAge,
                detail: "\(rhrDays) of last 7 nights"),
            FitnessReadinessItem(key: "activity", label: "Recent activity",
                status: coverageStatus(activityDays, floor: minCoverageDays), required: false, role: .drivesAge,
                detail: "\(activityDays) of last 7 days"),
            FitnessReadinessItem(key: "bodyMetrics", label: "Height & weight",
                status: hasHeightWeight ? .satisfied : .missing, required: false, role: .drivesAge,
                // Height/weight give the BMI behind the body factor (body fat replaces it when measured).
                detail: hasHeightWeight ? "Set" : "Add it in Settings"),
            FitnessReadinessItem(key: "waist", label: "Waist (optional)",
                status: hasWaist ? .satisfied : .missing, required: false, role: .unlocksVO2max,
                detail: hasWaist ? "Sharpens VO₂max" : "Optional - sharpens VO₂max"),
        ]
        let confidence: FitnessAgeConfidence
        if !hasAge || !hasSex || rhrDays < minCoverageDays {
            confidence = .notReady
        } else if rhrDays >= goodCoverageDays && activityDays >= goodCoverageDays {
            confidence = .ready
        } else {
            confidence = .estimate
        }
        return FitnessAgeReadiness(items: items, confidence: confidence)
    }
}

/// A computed Fitness Age plus what is needed to present it honestly.
public struct FitnessAgeResult: Equatable, Sendable {
    public let vo2max: Double?         // the VO₂max the age used (ml/kg/min), nil when none was usable
    public let fitnessAge: Double      // years, one decimal, within chronological ±15 and 18…90
    public let chronoAge: Double       // the user's calendar age
    public let deltaYears: Double      // chronoAge − fitnessAge (positive = younger than your age)
    public let bandYears: Double       // ± presentation band
    public let lowerConfidence: Bool   // true for non-binary (sex-specific norms) or sparse data
    /// Weighted years each present factor adds (positive = older). Sums to the unbounded offset.
    public let contributions: [FitnessAgeFactor: Double]
    /// True when the blend fell outside the bounds and `fitnessAge` sits on one.
    public let bounded: Bool

    public init(vo2max: Double?, fitnessAge: Double, chronoAge: Double,
                deltaYears: Double, bandYears: Double, lowerConfidence: Bool,
                contributions: [FitnessAgeFactor: Double] = [:], bounded: Bool = false) {
        self.vo2max = vo2max; self.fitnessAge = fitnessAge; self.chronoAge = chronoAge
        self.deltaYears = deltaYears; self.bandYears = bandYears; self.lowerConfidence = lowerConfidence
        self.contributions = contributions; self.bounded = bounded
    }
}

/// Stored series keys of fitness-age inputs that are not one-per-factor.
public enum FitnessAgeKeys {
    /// 1 when the VO₂max input was measured (Apple Health), 0 for the Nes estimate.
    public static let vo2Measured = "fitness_age_in_vo2max_measured"
    /// Body fat (%) the body factor used, when measured.
    public static let bodyFat = "fitness_age_in_body_fat"
    /// BMI the body factor used, when no body fat was measured.
    public static let bmi = "fitness_age_in_bmi"
}
