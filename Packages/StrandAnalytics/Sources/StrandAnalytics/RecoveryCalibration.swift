import Foundation

// Personal Charge (Recovery) weighting learned from a morning check-in: one question ("how recovered do you
// feel?", 1-5) plus symptom toggles (headache, soreness, ill, stress). Once enough mornings exist, each Charge
// term's weight is nudged by how well it tracked the wearer's answers.
//
// Guard rails:
//   - A weight moves at most +/-`maxShift` (50%) from standard, so noisy answers can't re-invent the model.
//   - The shift scales by `confidence` = mornings / `fullDays`; the preview from `previewDays` moves little.
//   - HRV stays the dominant weight; weights are renormalised to the standard total (re-balance, never inflate).
//   - Symptoms are not learned away: they enter as their own penalty term (`RecoveryScorer.wSymptoms`).
// Pure: no clock, no I/O.

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

    /// The documented RecoveryScorer weights, used by every caller that does not calibrate.
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

public enum ChargeTerm: String, CaseIterable, Codable, Sendable {
    case hrv, rhr, sleep, resp, skinTemp
}

/// One morning's self-report, saved field by field, so a check-in can be partial.
public struct MorningCheckIn: Equatable, Codable, Sendable {
    /// How recovered the wearer feels, 1 (exhausted) ... 5 (fully recovered); nil while unanswered. Only answered mornings enter the fit.
    public var feeling: Int?
    public var headache: Bool
    public var soreness: Bool
    public var ill: Bool
    public var stress: Bool

    public init(feeling: Int?, headache: Bool = false, soreness: Bool = false,
                ill: Bool = false, stress: Bool = false) {
        self.feeling = feeling
        self.headache = headache
        self.soreness = soreness
        self.ill = ill
        self.stress = stress
    }

    public static let scale: ClosedRange<Int> = 1...5

    /// True when nothing was answered.
    public var isEmpty: Bool { feeling == nil && !headache && !soreness && !ill && !stress }

    /// Symptom load in z-units for `RecoveryScorer.recovery(symptomLoad:)`; feeling ill weighs most. 0 when nothing reported (term skipped).
    public var symptomLoad: Double {
        (ill ? 2.0 : 0) + (headache ? 1.0 : 0) + (soreness ? 0.75 : 0) + (stress ? 0.75 : 0)
    }
}

/// One calibration sample: a night's Charge term z-scores and how the wearer felt that morning.
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

public struct RecoveryCalibrationResult: Equatable, Codable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// Fewer than `previewDays` answered mornings: standard weights.
        case collecting
        /// Partly personalised weights (confidence < 1).
        case preview
        /// `fullDays` or more mornings: full-strength weights, still updating.
        case calibrated
    }

    public let phase: Phase
    /// Answered mornings that had a scoreable night.
    public let mornings: Int
    public let confidence: Double
    public let weights: ChargeWeights
    /// Pearson r between each term's z and the morning feeling (terms with enough data only).
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

    /// Answered mornings before the weighting starts to move.
    public static let previewDays = 7
    /// Answered mornings for full-strength calibration; four weeks spans training/rest weeks and weekends so the fit doesn't learn one unusual week.
    public static let fullDays = 28
    /// Largest fractional move of any weight from standard.
    public static let maxShift = 0.5
    /// Correlation at which a term keeps its standard weight (moderate agreement is what a working term looks like); below loses weight, above gains.
    public static let neutralCorrelation = 0.2
    /// Correlation distance from `neutralCorrelation` that reaches the full +/-maxShift.
    public static let correlationSpan = 0.3

    /// The Charge term z-scores as `RecoveryScorer.recovery` builds them (higher = better); terms missing input or baseline are absent.
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

    /// Fits personal weights from the answered mornings.
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
            // A term with few pairs moves only as far as its own data supports.
            let termConfidence = min(confidence, Double(pairs.count) / Double(fullDays))
            let pull = max(-1.0, min(1.0, (r - neutralCorrelation) / correlationSpan))
            weights.set(term, standard.weight(term) * (1.0 + maxShift * termConfidence * pull))
        }
        weights = normalised(weights, toTotal: standard.total)
        return RecoveryCalibrationResult(phase: n >= fullDays ? .calibrated : .preview, mornings: n,
                                         confidence: confidence, weights: weights,
                                         correlations: correlations)
    }

    /// Rescales to `toTotal` keeping HRV dominant.
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

    /// Pearson correlation; nil when either side has no variance.
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
