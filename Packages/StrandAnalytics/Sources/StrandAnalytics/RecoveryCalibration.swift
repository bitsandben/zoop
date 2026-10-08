import Foundation

// RecoveryCalibration.swift — personal Charge (Recovery) weighting learned from a morning check-in.
//
// Zoop fork. The wearer answers one question each morning ("how recovered do you feel?", 1–5) plus a few
// symptom toggles (headache, muscle soreness, feeling ill, stress). Once enough mornings exist, each
// Charge term's weight is nudged by how well that term tracked the wearer's own answers: a term whose
// z-score rises and falls with how they feel gains weight, one that does not loses weight.
//
// Guard rails, all deliberate:
//   - A weight moves at most ±`maxShift` (50 %) from its standard value, so 28 noisy answers cannot
//     re-invent the model; the physiology stays in charge.
//   - The shift is scaled by `confidence` = mornings / `fullDays`, so the preview from `previewDays`
//     onward moves the weights only a little and sharpens as answers accumulate.
//   - HRV stays the dominant weight (never below any other term), matching WHOOP's public description.
//   - Weights are renormalised to the standard total, so calibration re-balances, it never inflates.
//   - Symptoms are NOT learned away: they enter as their own penalty term (`RecoveryScorer.wSymptoms`) on
//     the morning they are reported, independent of the weights.
//
// Pure and side-effect-free: no clock, no I/O.

/// The per-term weights `RecoveryScorer.recovery` composes Charge with.
public struct ChargeWeights: Equatable, Codable, Sendable {
    public var hrv: Double
    public var rhr: Double
    public var sleep: Double
    public var resp: Double
    public var skinTemp: Double

    public init(hrv: Double, rhr: Double, sleep: Double, resp: Double, skinTemp: Double) {
        self.hrv = hrv
        self.rhr = rhr
        self.sleep = sleep
        self.resp = resp
        self.skinTemp = skinTemp
    }

    /// The documented RecoveryScorer weights. Every caller that does not calibrate scores with these.
    public static let standard = ChargeWeights(hrv: RecoveryScorer.wHRV, rhr: RecoveryScorer.wRHR,
                                               sleep: RecoveryScorer.wSleep, resp: RecoveryScorer.wResp,
                                               skinTemp: RecoveryScorer.wSkinTemp)

    public func weight(_ term: ChargeTerm) -> Double {
        switch term {
        case .hrv: return hrv
        case .rhr: return rhr
        case .sleep: return sleep
        case .resp: return resp
        case .skinTemp: return skinTemp
        }
    }

    mutating func set(_ term: ChargeTerm, _ value: Double) {
        switch term {
        case .hrv: hrv = value
        case .rhr: rhr = value
        case .sleep: sleep = value
        case .resp: resp = value
        case .skinTemp: skinTemp = value
        }
    }

    var total: Double { ChargeTerm.allCases.reduce(0) { $0 + weight($1) } }
}

/// The calibratable Charge terms.
public enum ChargeTerm: String, CaseIterable, Codable, Sendable {
    case hrv, rhr, sleep, resp, skinTemp
}

/// One morning's self-report.
public struct MorningCheckIn: Equatable, Codable, Sendable {
    /// How recovered the wearer feels, 1 (exhausted) … 5 (fully recovered).
    public var feeling: Int
    public var headache: Bool
    public var soreness: Bool
    public var ill: Bool
    public var stress: Bool

    public init(feeling: Int, headache: Bool = false, soreness: Bool = false,
                ill: Bool = false, stress: Bool = false) {
        self.feeling = feeling
        self.headache = headache
        self.soreness = soreness
        self.ill = ill
        self.stress = stress
    }

    public static let scale: ClosedRange<Int> = 1...5

    /// Symptom load in z-units for `RecoveryScorer.recovery(symptomLoad:)`. Feeling ill weighs most since
    /// it is the strongest sign the body is fighting something; the others are ordinary morning burdens.
    /// 0 when nothing was reported, so the term is skipped.
    public var symptomLoad: Double {
        (ill ? 2.0 : 0) + (headache ? 1.0 : 0) + (soreness ? 0.75 : 0) + (stress ? 0.75 : 0)
    }
}

/// One calibration sample: the Charge term z-scores of a night and how the wearer felt that morning.
public struct CalibrationSample: Equatable, Sendable {
    public let day: String
    public let feeling: Double
    public let termZ: [ChargeTerm: Double]

    public init(day: String, feeling: Double, termZ: [ChargeTerm: Double]) {
        self.day = day
        self.feeling = feeling
        self.termZ = termZ
    }
}

/// Outcome of a calibration fit.
public struct RecoveryCalibrationResult: Equatable, Codable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// Fewer than `previewDays` answered mornings: standard weights, nothing learned yet.
        case collecting
        /// Weights are already personalised, but only partly (confidence < 1).
        case preview
        /// `fullDays` or more mornings: full-strength personal weights, still updating with every answer.
        case calibrated
    }

    public let phase: Phase
    /// Answered mornings that had a scoreable night.
    public let mornings: Int
    /// mornings / fullDays, capped at 1.
    public let confidence: Double
    public let weights: ChargeWeights
    /// Pearson r between each term's z and the morning feeling (only terms with enough data).
    public let correlations: [String: Double]

    public init(phase: Phase, mornings: Int, confidence: Double, weights: ChargeWeights,
                correlations: [String: Double]) {
        self.phase = phase
        self.mornings = mornings
        self.confidence = confidence
        self.weights = weights
        self.correlations = correlations
    }

    public static let empty = RecoveryCalibrationResult(phase: .collecting, mornings: 0, confidence: 0,
                                                        weights: .standard, correlations: [:])
}

public enum RecoveryCalibration {

    /// Answered mornings before the personal weighting starts to move (the preview).
    public static let previewDays = 7
    /// Answered mornings for full-strength calibration. Four weeks spans training and rest weeks,
    /// weekends and a typical hormonal cycle, so the fit does not learn one unusual week.
    public static let fullDays = 28
    /// Largest fractional move of any weight away from its standard value.
    public static let maxShift = 0.5
    /// Correlation at which a term keeps its standard weight. Moderate agreement between a single
    /// physiological signal and a 1–5 feeling is what a working term looks like, so below it a term
    /// loses weight and above it gains.
    public static let neutralCorrelation = 0.2
    /// Correlation distance from `neutralCorrelation` that reaches the full ±maxShift.
    public static let correlationSpan = 0.3

    /// The Charge term z-scores exactly as `RecoveryScorer.recovery` builds them (higher = better
    /// recovery). Terms whose input or baseline is missing are absent.
    public static func termZScores(hrv: Double, rhr: Double, resp: Double?,
                                   hrvBaseline: BaselineState, rhrBaseline: BaselineState?,
                                   respBaseline: BaselineState?, sleepPerf: Double?,
                                   skinTempDev: Double?) -> [ChargeTerm: Double] {
        var z: [ChargeTerm: Double] = [:]
        guard hrvBaseline.usable else { return z }
        z[.hrv] = RecoveryScorer.zScore(hrv, mean: hrvBaseline.baseline, spread: hrvBaseline.spread)
        if let b = rhrBaseline, b.usable {
            z[.rhr] = RecoveryScorer.zScore(b.baseline, mean: rhr, spread: b.spread)
        }
        if let r = resp, let b = respBaseline {
            z[.resp] = RecoveryScorer.zScore(b.baseline, mean: r, spread: b.spread)
        }
        if let sp = sleepPerf {
            z[.sleep] = (sp - RecoveryScorer.sleepPerfCenter) / RecoveryScorer.sleepPerfScale
        }
        if let dev = skinTempDev {
            z[.skinTemp] = -abs(dev) / RecoveryScorer.skinTempScaleC
        }
        return z
    }

    /// Fit personal weights from the answered mornings.
    public static func fit(_ samples: [CalibrationSample]) -> RecoveryCalibrationResult {
        let n = samples.count
        guard n >= previewDays else {
            return RecoveryCalibrationResult(phase: .collecting, mornings: n, confidence: 0,
                                             weights: .standard, correlations: [:])
        }
        let confidence = min(1.0, Double(n) / Double(fullDays))
        let standard = ChargeWeights.standard
        var weights = standard
        var correlations: [String: Double] = [:]
        for term in ChargeTerm.allCases {
            let pairs = samples.compactMap { s in s.termZ[term].map { ($0, s.feeling) } }
            guard pairs.count >= previewDays, let r = pearson(pairs) else { continue }
            correlations[term.rawValue] = r
            // A term with too few of its own pairs only moves as far as its own data supports.
            let termConfidence = min(confidence, Double(pairs.count) / Double(fullDays))
            let pull = max(-1.0, min(1.0, (r - neutralCorrelation) / correlationSpan))
            weights.set(term, standard.weight(term) * (1.0 + maxShift * termConfidence * pull))
        }
        weights = normalised(weights, toTotal: standard.total)
        return RecoveryCalibrationResult(phase: n >= fullDays ? .calibrated : .preview, mornings: n,
                                         confidence: confidence, weights: weights,
                                         correlations: correlations)
    }

    /// Rescale to `toTotal` and keep HRV the dominant weight.
    static func normalised(_ w: ChargeWeights, toTotal total: Double) -> ChargeWeights {
        var out = w
        for _ in 0..<3 {
            let sum = out.total
            guard sum > 0 else { return .standard }
            for t in ChargeTerm.allCases { out.set(t, out.weight(t) * total / sum) }
            let topOther = ChargeTerm.allCases.filter { $0 != .hrv }.map { out.weight($0) }.max() ?? 0
            if out.hrv >= topOther { break }
            out.hrv = topOther
        }
        return out
    }

    /// Pearson correlation, nil when either side has no variance.
    static func pearson(_ pairs: [(Double, Double)]) -> Double? {
        let n = Double(pairs.count)
        guard n >= 2 else { return nil }
        let mx = pairs.reduce(0) { $0 + $1.0 } / n
        let my = pairs.reduce(0) { $0 + $1.1 } / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in pairs {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
            syy += (y - my) * (y - my)
        }
        guard sxx > 1e-12, syy > 1e-12 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }
}
