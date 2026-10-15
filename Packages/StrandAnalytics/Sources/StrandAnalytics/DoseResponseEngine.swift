import Foundation

// DoseResponseEngine.swift - a personal dose-to-outcome slope that shrinks toward a documented
// population prior until the user has logged enough nights.
//
// Pure, deterministic, DB-free. For a dosed journal behaviour (alcohol: drinks 0..3+; caffeine: a
// time-of-day bucket 0..3):
//   1. Pair (dose_d, outcome_{d+1}) for each logged day (L=1 alignment via CorrelationEngine.shiftDay).
//   2. beta_user = the OLS slope from CorrelationEngine.pearson (needs >= 3 pairs and spread in both
//      axes, else undefined and the result is pure prior); n_user = paired days.
//   3. Shrink toward beta_prior (DoseResponsePriors): beta = w*beta_user + (1-w)*beta_prior,
//      w = n_user/(n_user + k), k = shrinkageK; then clamp to the prior's sane range.
//   4. Report the per-unit delta (beta), curve points, and a ScoreConfidence from n_user / w.
//
// Honesty: below the dose gate (n_user < minDoseDays) the result is `priorDominated`; once there
// is enough data the person overrides the population, and `contradictsPrior` flags when the
// personal slope disagrees. Caffeine "dose" is a timing proxy, never mg. Association on the user's
// own logged days, not a causal or clinical claim.

// MARK: - Result

/// A personal, prior-shrunk dose-response estimate for one dosed behaviour on one outcome.
public struct DoseResponse: Equatable, Sendable {
    public let behavior: DosedBehavior
    /// The outcome label the slope is expressed in (e.g. "Charge", "HRV").
    public let outcome: String
    /// The shrunk, clamped effect per one extra unit of dose (signed): the headline "each extra drink".
    public let perUnit: Double
    /// The user's own OLS slope, or nil when there weren't enough pairs with spread to fit.
    public let userSlope: Double?
    public let priorSlope: Double
    /// The shrinkage weight w = n_user/(n_user + k) in [0, 1]; 0 = pure prior, 1 = pure personal.
    public let weight: Double
    public let nUser: Int
    /// True while the estimate is mostly the prior (n_user below the dose gate).
    public let priorDominated: Bool
    /// True when the user has enough data and their slope's sign disagrees with the prior.
    public let contradictsPrior: Bool
    public let confidence: ScoreConfidence
    /// Curve points (dose, outcome delta from a 0-dose anchor of 0) for dose 0...maxCurveDose, using
    /// the shrunk slope; relative so the UI can offset onto any baseline.
    public let curve: [DoseCurvePoint]

    public init(behavior: DosedBehavior, outcome: String, perUnit: Double,
                userSlope: Double?, priorSlope: Double, weight: Double, nUser: Int,
                priorDominated: Bool, contradictsPrior: Bool,
                confidence: ScoreConfidence, curve: [DoseCurvePoint]) {
        self.behavior = behavior
        self.outcome = outcome
        self.perUnit = perUnit
        self.userSlope = userSlope
        self.priorSlope = priorSlope
        self.weight = weight
        self.nUser = nUser
        self.priorDominated = priorDominated
        self.contradictsPrior = contradictsPrior
        self.confidence = confidence
        self.curve = curve
    }

    /// The signed delta on the outcome for going from `fromDose` to `toDose`; each unit contributes `perUnit`.
    public func delta(fromDose: Int, toDose: Int) -> Double {
        Double(toDose - fromDose) * perUnit
    }

    /// Plain-English read, honest about whether it's still the prior or the user's own.
    public func sentence() -> String {
        let mag = DoseResponseEngine.round1(abs(perUnit))
        let dir = perUnit <= 0 ? "lower" : "higher"
        if priorDominated {
            return "Each extra unit typically lines up with about \(mag) \(outcome) \(dir) "
                + " - typical patterns, not yet yours (n=\(nUser))."
        }
        if contradictsPrior {
            return "In your data so far, this doesn't move your \(outcome) the way it typically "
                + "does (n=\(nUser))."
        }
        return "Each extra unit tends to line up with about \(mag) \(outcome) \(dir) for you "
            + "(n=\(nUser))."
    }
}

/// One point on the personal dose-response curve: a dose level and its modelled outcome delta from the 0-dose anchor.
public struct DoseCurvePoint: Equatable, Sendable {
    public let dose: Int
    public let outcomeDelta: Double
    public init(dose: Int, outcomeDelta: Double) {
        self.dose = dose
        self.outcomeDelta = outcomeDelta
    }
}

// MARK: - Engine

public enum DoseResponseEngine {

    // MARK: Tunables (documented, deterministic, not learned)

    /// Pseudo-count of "prior days": k in w = n/(n+k). At n_user = k the blend is 50/50.
    public static let shrinkageK: Double = 8.0
    /// Paired days below which the estimate is `priorDominated`.
    public static let minDoseDays: Int = 5
    public static let solidDoseDays: Int = 12
    /// The highest dose level the curve enumerates, matching the 0/1/2/3+ axis.
    public static let maxCurveDose: Int = 3

    // MARK: - Estimate

    /// Estimates the prior-shrunk dose-response for a behaviour against its default outcome.
    ///
    /// - Parameters:
    ///   - behavior: the dosed behaviour (needs a documented prior).
    ///   - doseByDay: dose integer (>= 0) per "yyyy-MM-dd".
    ///   - outcomeByDay: the daily outcome series keyed "yyyy-MM-dd".
    /// - Returns: a `DoseResponse`, or nil when no prior is documented.
    public static func estimate(behavior: DosedBehavior,
                                doseByDay: [String: Int],
                                outcomeByDay: [String: Double]) -> DoseResponse? {
        let outcome = DoseResponsePriors.defaultOutcome(for: behavior)
        return estimate(behavior: behavior, outcome: outcome,
                        doseByDay: doseByDay, outcomeByDay: outcomeByDay)
    }

    /// Estimates against a named outcome; nil when `(behaviour, outcome)` has no documented prior.
    public static func estimate(behavior: DosedBehavior,
                                outcome: String,
                                doseByDay: [String: Int],
                                outcomeByDay: [String: Double]) -> DoseResponse? {
        guard let prior = DoseResponsePriors.prior(for: behavior, outcome: outcome) else { return nil }

        // Pair each logged dose day D with the next-day outcome (D+1).
        var pairs: [(Double, Double)] = []
        // Sorted day keys keep the pair order, and any float reduction, deterministic.
        for day in doseByDay.keys.sorted() {
            let dose = doseByDay[day]!
            guard let d1 = CorrelationEngine.shiftDay(day, by: 1),
                  let outVal = outcomeByDay[d1] else { continue }
            pairs.append((Double(dose), outVal))
        }
        let nUser = pairs.count

        // Personal OLS slope (nil if < 3 pairs or no spread in either axis).
        let userSlope = CorrelationEngine.pearson(pairs)?.slope

        // Shrinkage weight: 0 with no data, approaching 1 past k.
        let w = Double(nUser) / (Double(nUser) + shrinkageK)

        // Blend, then clamp to the prior's range. Without a usable personal slope this is the prior alone.
        let blended: Double
        if let us = userSlope {
            blended = w * us + (1.0 - w) * prior.slopePerUnit
        } else {
            blended = prior.slopePerUnit
        }
        let perUnit = clamp(blended, prior.clampLow, prior.clampHigh)

        let priorDominated = nUser < minDoseDays
        // The person overrides the population only with enough data and a sign disagreement; a flat
        // personal slope counts as contradicting a non-zero prior.
        let contradicts: Bool
        if let us = userSlope, nUser >= minDoseDays {
            contradicts = !sameSign(us, prior.slopePerUnit)
        } else {
            contradicts = false
        }

        let confidence = confidenceFor(nUser: nUser)

        // Curve: relative delta from a 0-dose anchor using perUnit.
        var curve: [DoseCurvePoint] = []
        for dose in 0...maxCurveDose {
            curve.append(DoseCurvePoint(dose: dose, outcomeDelta: Double(dose) * perUnit + 0.0)) // +0.0 normalises -0.0 → 0.0
        }

        return DoseResponse(behavior: behavior, outcome: outcome, perUnit: perUnit,
                            userSlope: userSlope, priorSlope: prior.slopePerUnit,
                            weight: w, nUser: nUser, priorDominated: priorDominated,
                            contradictsPrior: contradicts, confidence: confidence, curve: curve)
    }

    // MARK: - Confidence

    /// Calibrating while mostly prior (n_user < minDoseDays), building while blended, solid at n_user >= solidDoseDays.
    static func confidenceFor(nUser: Int) -> ScoreConfidence {
        if nUser < minDoseDays { return .calibrating }
        return nUser >= solidDoseDays ? .solid : .building
    }

    // MARK: - Helpers

    /// True when a and b share a sign; zero counts as not matching a non-zero value.
    static func sameSign(_ a: Double, _ b: Double) -> Bool {
        if a > 0 && b > 0 { return true }
        if a < 0 && b < 0 { return true }
        if a == 0 && b == 0 { return true }
        return false
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(x, lo), hi)
    }

    /// Rounds to one decimal place (half away from zero).
    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
