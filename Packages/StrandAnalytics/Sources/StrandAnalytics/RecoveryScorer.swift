import Foundation
import WhoopProtocol

// Resting HR during sleep and a transparent 0-100 recovery score ("Charge" in the UI).
//
// recovery() is a z-score + logistic composite: an HRV-dominant, baseline-normalized proxy, approximate and not
// WHOOP-identical (WHOOP's model is proprietary). Weights:
//   higher HRV vs baseline       -> higher recovery  (W_HRV       = 0.55, dominant)
//   lower resting HR vs baseline -> higher recovery  (W_RHR       = 0.20)
//   higher rest quality (sleep)  -> higher recovery  (W_SLEEP     = 0.15)
//   lower resp vs baseline       -> higher recovery  (W_RESP      = 0.05)
//   skin-temp deviation from 0   -> lower recovery   (W_SKIN_TEMP = 0.05)
//
// Skin temp is a symmetric penalty on the +/- deg C deviation (-|dev|/scale): drift either way lowers Charge.
// Two more optional nil-default terms (a validation found Charge already tracks Oura readiness at r~0.71; these
// are components it lacked): overnight resting-HR decline slope ("Recovery Index", W = 0.05) and previous-day
// Effort vs its personal baseline ("Activity Balance", W = 0.05, needs both the value and
// `Baselines.strainCfg` baseline). Each folds in only when supplied; when nil the term drops and weights
// renormalize, so the default score is unchanged.
//
// Each metric is a robust z against the personal baseline (mean + EWMA-abs-dev spread). Missing terms drop and
// weights renormalize. The composite z goes through a logistic anchored so Z = 0 -> ~58% (WHOOP's published
// population-average recovery). Cold start: recovery() returns nil while the HRV baseline has fewer than
// MIN_NIGHTS_SEED valid nights; callers may fall back to RECOVERY_POPULATION_MEAN (58.0) but should flag it.

public enum RecoveryScorer {

    // MARK: - Constants

    public static let wHRV: Double = 0.55
    public static let wRHR: Double = 0.20
    public static let wResp: Double = 0.05
    public static let wSleep: Double = 0.15
    /// Skin-temperature deviation weight (HRV gave up 0.05 to fund it).
    public static let wSkinTemp: Double = 0.05

    /// Skin-temp penalty scale (deg C): a 1 deg C deviation costs ~1 z-unit before weighting; symmetric.
    public static let skinTempScaleC: Double = 1.0

    /// Recovery-Index weight (overnight resting-HR decline slope); folds in only when a slope is supplied.
    public static let wRecoveryIndex: Double = 0.05

    /// Recovery-Index slope scale (bpm/hour): a slope this steeper than flat costs/earns ~1 z-unit. Resting HR
    /// falling through the night is the expected good pattern; flat or rising (illness, alcohol, restlessness) is
    /// not. Unlike skin-temp, the sign carries meaning (negative = good).
    public static let recoveryIndexScaleBpmPerHr: Double = 2.0

    /// Activity-Balance / previous-day-Effort weight; folds in only when both a previous-day Effort and its EWMA baseline are supplied.
    public static let wActivityBalance: Double = 0.05

    /// Weight of the morning check-in symptom term; added only when a symptom was reported.
    public static let wSymptoms: Double = 0.10
    /// Ceiling on symptom load (z-units) so a check-in can lower Charge but never floor it alone.
    public static let symptomLoadCap: Double = 3.0

    /// Logistic spread: +/-2 z-units ~ full Red-Green band (15%-95%).
    public static let logisticK: Double = 1.6
    /// Logistic offset so Z = 0 -> 58%.
    public static let logisticZ0: Double = -0.20
    /// WHOOP-published population-average recovery (%); cold-start fallback.
    public static let populationMean: Double = 58.0

    /// Recovery band threshold (WHOOP colour scheme).
    public static let bandRedMax: Double = 34.0
    public static let bandYellowMax: Double = 67.0

    /// Sleep-performance centre ("good night" at ~85% efficiency).
    public static let sleepPerfCenter: Double = 0.85
    /// Sleep-performance scale (+/-2 z spans the normal range).
    public static let sleepPerfScale: Double = 0.12

    // MARK: - Parasympathetic-saturation guard (Charge): DETECTED AND LOGGED, NOT APPLIED
    //
    // Low HRV normally pulls Charge down via the dominant HRV term. A candidate benign exception is parasympathetic
    // (vagal) saturation: in a very fit or relaxed state RMSSD can read LOW while resting HR also reads LOW (the two
    // decouple). The discriminator is the sign of the RHR term vs the HRV term: normally low HRV travels with HIGH
    // resting HR, so both terms point down; when the HRV term is "bad" but the RHR term is "good", the coupling broke.
    //
    // The easing is computed and reported but `recovery(...)` does not consume it, so Charge is unchanged:
    //   1. Validation gap: real data recorded zero firings over ~2 weeks. That shows the gate doesn't over-fire, not
    //      that the easing is the right size on a real saturation night (covered by synthetic fixtures only, see
    //      RecoverySaturationGuardTests).
    //   2. Contested premise: low HRV + low resting HR is also a signature of non-functional parasympathetic
    //      overreaching, which is maladaptive. The pair can't tell them apart, and they want opposite corrections.
    //
    // So it ships instrument-first: detection surfaces in the Charge trace ("charge saturation active ...
    // wouldRaiseCharge=N") and the ChargeDrivers HRV verdict. To enable later, feed `easedHrvZ` into the HRV term at
    // the marked call site in `recovery(...)` and flip the tests that pin the score as unchanged, gated on confirmed real firings.

    /// Personal-sigma units both the low-HRV and low-RHR arms must clear before the guard engages (0.5 keeps it off marginal/noise nights).
    public static let satEnterZ: Double = 0.5

    /// Personal-sigma units at which the signal reaches full strength; easing ramps linearly from satEnterZ to here (1.5 SD on both = unambiguous).
    public static let satFullZ: Double = 1.5

    /// Maximum fraction of the low-HRV penalty the easing would credit back (0.5: at least half always survives); today it only bounds the reported would-be delta.
    public static let satMaxDampFraction: Double = 0.5

    /// Outcome of the saturation check for one night. Counterfactual: `easedHrvZ` / `dampFraction` describe the
    /// easing the guard WOULD apply; `recovery(...)` does not consume them. They exist to be logged by the Charge
    /// trace and ChargeDrivers verdict.
    struct ParasympatheticSaturation: Equatable, Sendable {
        /// The HRV z the easing would use: the input shrunk toward 0 (never past it); equals the input when inactive. Not fed to the score.
        let easedHrvZ: Double
        /// True iff the saturation regime was detected; the Charge number is the same either way.
        let active: Bool
        /// Fraction of the HRV penalty the easing would credit back, in [0, satMaxDampFraction]; 0 when inactive.
        let dampFraction: Double
    }

    /// Detects parasympathetic saturation and computes the easing that WOULD apply to the low-HRV penalty. Pure
    /// detection plus a counterfactual: it has no effect on Charge (see the MARK header).
    ///
    /// - Parameters:
    ///   - hrvZ: the HRV term as recovery() builds it, (hrv - mu)/sigma; negative = below baseline (penalty).
    ///   - rhrZ: the RHR term, (mu - rhr)/sigma; positive = resting HR below baseline. Nil (no RHR baseline) means
    ///     nothing corroborates the low HRV, so the guard never fires.
    static func parasympatheticSaturation(hrvZ: Double, rhrZ: Double?) -> ParasympatheticSaturation {
        // No resting-HR term: benign saturation and real fatigue are indistinguishable from HRV alone.
        guard let rhrZ = rhrZ else {
            return ParasympatheticSaturation(easedHrvZ: hrvZ, active: false, dampFraction: 0)
        }
        // Signature in personal-sigma units (hrvLow > 0: HRV below baseline; rhrLow > 0: resting HR below baseline).
        // Both must clear satEnterZ, so a low-HRV + HIGH-RHR fatigue night (rhrLow < 0) never qualifies.
        let hrvLow = -hrvZ
        let rhrLow = rhrZ
        guard hrvLow >= satEnterZ, rhrLow >= satEnterZ else {
            return ParasympatheticSaturation(easedHrvZ: hrvZ, active: false, dampFraction: 0)
        }
        // Strength follows the weaker arm (conservative), normalized from the entry gate to satFullZ and clamped to [0, 1].
        let couplingStrength = min(hrvLow, rhrLow)
        let s = max(0.0, min(1.0, (couplingStrength - satEnterZ) / (satFullZ - satEnterZ)))
        let dampFraction = satMaxDampFraction * s
        // Shrink the negative HRV z toward 0; (1 - dampFraction) stays in [1 - satMaxDampFraction, 1], so the penalty is only reduced, never removed or flipped. Reporting only.
        let easedHrvZ = hrvZ * (1.0 - dampFraction)
        return ParasympatheticSaturation(easedHrvZ: easedHrvZ,
                                         active: dampFraction > 0,
                                         dampFraction: dampFraction)
    }

    // MARK: - Recovery band

    /// WHOOP-style colour band for a recovery score [0, 100].
    public static func band(_ score: Double) -> String {
        if score < bandRedMax { return "red" }
        if score < bandYellowMax { return "yellow" }
        return "green"
    }

    // MARK: - Cold-start calibration progress

    /// The recovery baseline's real seed count while it still cold-starts, for the dashboard's "Calibrating - N of
    /// <seed> nights" progress; nil once recovery exists or the baseline has crossed the seed gate. N is the HRV
    /// baseline's `nValid` from the same day-keyed, epoch-aware fold the engine uses
    /// (`Baselines.foldHistory(_:dayKeys:cfg:baselineEpoch:)`), because a looser per-night count kept advancing on
    /// nights the fold drops after a manual "Recalibrate HRV baseline" (#393 follow-up). `baselineEpoch` nil reads
    /// the persisted HRV epoch from UserDefaults like the engine.
    public static func calibrationNights(nightlyHrv: [Double?],
                                         dayKeys: [String],
                                         hasRecovery: Bool,
                                         seed: Int = Baselines.minNightsSeed,
                                         cfg: MetricCfg = Baselines.hrvCfg,
                                         baselineEpoch: Double? = nil) -> Int? {
        guard !hasRecovery else { return nil }
        let n = Baselines.foldHistory(nightlyHrv, dayKeys: dayKeys, cfg: cfg,
                                      baselineEpoch: baselineEpoch).nValid
        // Include 0 so a brand-new user reads "Calibrating - 0 of N" rather than a bare "No data" (#335); >= seed still returns nil.
        return (0..<seed).contains(n) ? n : nil
    }

    // MARK: - Recovery score

    /// A baseline driver: mean + spread (internal abs-dev units, as in BaselineState).
    public struct DriverBaseline: Equatable, Sendable {
        public let mean: Double
        public let spread: Double
        public init(mean: Double, spread: Double) {
            self.mean = mean; self.spread = spread
        }
        public init(_ state: BaselineState) {
            self.mean = state.baseline; self.spread = state.spread
        }
    }

    /// Robust z-score using EWMA spread: (value - mean) / (1.253 x spread).
    static func zScore(_ value: Double, mean: Double, spread: Double) -> Double {
        let sigma = max(1.253 * spread, 1e-9)
        return (value - mean) / sigma
    }

    /// Z-score + logistic recovery score in [0, 100], approximate. Nil when the HRV baseline (dominant driver) is
    /// not usable or no valid driver exists.
    ///
    /// - Parameters:
    ///   - hrv: tonight's HRV (RMSSD, ms).
    ///   - rhr: tonight's resting HR (bpm).
    ///   - resp: tonight's respiration (z is scale-invariant); nil drops the term.
    ///   - hrvBaseline: required for a score.
    ///   - rhrBaseline: nil drops the RHR term. On the `BaselineState` overload an unusable baseline (#1988) counts as nil.
    ///   - respBaseline: nil drops the resp term.
    ///   - sleepPerf: Rest quality (composite / 100, 0..1); nil drops the term.
    ///   - skinTempDev: skin-temperature deviation (+/- deg C, `DailyMetric.skinTempDevC`), a symmetric penalty at weight wSkinTemp; nil drops it.
    ///   - hrvBaselineUsable: whether the HRV baseline has enough nights; false returns nil (cold start).
    ///   - recoveryIndexSlope: overnight resting-HR decline slope (bpm/hour); negative supports recovery, positive limits it (wRecoveryIndex). Nil drops the term.
    ///   - effortBaseline: personal EWMA baseline of daily Effort (`Baselines.strainCfg`); needs `priorDayEffort` too, one alone drops the term.
    ///   - priorDayEffort: yesterday's Effort (0-100); lower vs baseline supports recovery (wActivityBalance). Nil drops the term.
    public static func recovery(hrv: Double,
                                rhr: Double,
                                resp: Double?,
                                hrvBaseline: DriverBaseline?,
                                rhrBaseline: DriverBaseline?,
                                respBaseline: DriverBaseline?,
                                sleepPerf: Double?,
                                skinTempDev: Double? = nil,
                                hrvBaselineUsable: Bool = true,
                                recoveryIndexSlope: Double? = nil,
                                effortBaseline: DriverBaseline? = nil,
                                priorDayEffort: Double? = nil,
                                weights: ChargeWeights = .standard,
                                symptomLoad: Double? = nil) -> Double? {
        // Cold-start gate: refuse to score without a usable HRV baseline rather than fabricate a value.
        if !hrvBaselineUsable { return nil }
        // Required-driver gate: without this an absent baseline let other optional terms (e.g. sleepPerf alone) score Charge with no HRV term.
        guard let hrvB = hrvBaseline else { return nil }

        var terms: [(z: Double, w: Double)] = []

        // HRV term: higher is better. Instrument-first call site for the saturation guard: this is the RAW z, so Charge
        // is unchanged; swap in `parasympatheticSaturation(hrvZ:rhrZ:).easedHrvZ` here to enable it (see the MARK header).
        terms.append((zScore(hrv, mean: hrvB.mean, spread: hrvB.spread), weights.hrv))
        // RHR term: lower is better -> (mu - x) / sigma.
        if let b = rhrBaseline {
            terms.append((zScore(b.mean, mean: rhr, spread: b.spread), weights.rhr))
        }
        // Resp term: lower is better, optional.
        if let r = resp, let b = respBaseline {
            terms.append((zScore(b.mean, mean: r, spread: b.spread), weights.resp))
        }
        // Sleep-performance / Rest-quality term: no baseline, centred at sleepPerfCenter.
        if let sp = sleepPerf {
            terms.append(((sp - sleepPerfCenter) / sleepPerfScale, weights.sleep))
        }
        // Skin-temp term: symmetric penalty on |deviation|; added only when supplied.
        if let dev = skinTempDev {
            terms.append((-abs(dev) / skinTempScaleC, weights.skinTemp))
        }
        // Recovery-Index term: overnight HR-decline slope (bpm/hour), fixed scale, no baseline; negative supports recovery. Only when supplied.
        if let slope = recoveryIndexSlope {
            terms.append((-slope / recoveryIndexScaleBpmPerHr, wRecoveryIndex))
        }
        // Activity-Balance term: lower prior-day Effort vs baseline is better, (mu - x) / sigma; needs both value and baseline.
        if let e = priorDayEffort, let b = effortBaseline {
            terms.append((zScore(b.mean, mean: e, spread: b.spread), wActivityBalance))
        }
        // Morning check-in symptoms: only a positive load adds the term, so "no symptoms" never dilutes the others toward the population mean.
        if let load = symptomLoad, load > 0 {
            terms.append((-min(load, symptomLoadCap), wSymptoms))
        }

        guard !terms.isEmpty else { return nil }
        let totalWeight = terms.reduce(0) { $0 + $1.w }
        guard totalWeight > 0 else { return nil }

        let z = terms.reduce(0) { $0 + $1.z * $1.w } / totalWeight
        return logisticScore(compositeZ: z)
    }

    /// The Charge logistic: weighted composite z -> 0-100, clamped. Shared with the trace's saturation counterfactual so both run the exact same curve.
    static func logisticScore(compositeZ z: Double) -> Double {
        let score = 100.0 / (1.0 + exp(-logisticK * (z - logisticZ0)))
        return max(0.0, min(100.0, score))
    }

    /// Convenience overload taking BaselineState directly; enforces the cold-start gate via `hrvBaseline.usable`.
    public static func recovery(hrv: Double,
                                rhr: Double,
                                resp: Double?,
                                hrvBaseline: BaselineState,
                                rhrBaseline: BaselineState?,
                                respBaseline: BaselineState?,
                                sleepPerf: Double?,
                                skinTempDev: Double? = nil,
                                recoveryIndexSlope: Double? = nil,
                                effortBaseline: BaselineState? = nil,
                                priorDayEffort: Double? = nil,
                                weights: ChargeWeights = .standard,
                                symptomLoad: Double? = nil) -> Double? {
        recovery(hrv: hrv,
                 rhr: rhr,
                 resp: resp,
                 hrvBaseline: DriverBaseline(hrvBaseline),
                 // #1988: an unusable resting-HR baseline is treated as absent. foldHistory returns a synthetic midpoint (~75 bpm)
                 // for an empty or all-implausible history, which is nobody's resting HR. Gated here, where every BaselineState
                 // caller passes, so the headline and driver breakdown agree.
                 rhrBaseline: rhrBaseline.flatMap { $0.usable ? $0 : nil }.map(DriverBaseline.init),
                 respBaseline: respBaseline.map(DriverBaseline.init),
                 sleepPerf: sleepPerf,
                 skinTempDev: skinTempDev,
                 hrvBaselineUsable: hrvBaseline.usable,
                 recoveryIndexSlope: recoveryIndexSlope,
                 effortBaseline: effortBaseline.map(DriverBaseline.init),
                 priorDayEffort: priorDayEffort,
                 weights: weights,
                 symptomLoad: symptomLoad)
    }
}
