import Foundation

// Charge term-breakdown diagnostic (Recovery test mode). Recomputes the weighted Charge terms from the same
// inputs `RecoveryScorer.recovery` reads and reuses `recovery(...)` verbatim for the final score, so the trace
// can never disagree with the dashboard. Pure; gated by TestCentre.active(.recovery) at the call site
// (IntelligenceEngine recomputeRecovery). Counts, z-scores and weights only, no PII.

extension RecoveryScorer {

    /// Two-decimal rounding contract: round `x * 100` half-ties away from zero, divide by 100, keep the IEEE sign
    /// bit (so a driver term rounding to zero from below renders `-0.0`, #1437). Rounds in the Double domain on
    /// purpose: Kotlin's `Math.round` returns a saturating `Long` (#47). Non-finite or overflowing input passes
    /// through as infinity/NaN.
    static func traceRound2(_ x: Double) -> Double {
        (x * 100.0).rounded(.toNearestOrAwayFromZero) / 100.0
    }

    /// Diagnostic twin of `recovery(...)`: returns the same score plus a per-term Charge breakdown (baseline line
    /// per driver, z x weight per term, renormalization, final logistic score and band). It names which term was nil
    /// and forced the renormalization, so a "Charge looks wrong" report shows which driver moved or was missing.
    /// Every number uses the same expressions as `recovery(...)`, and the returned score is `recovery(...)` verbatim.
    ///
    /// - Parameters mirror `recovery(...)`, taking BaselineState so each driver's nValid / status can be read; the
    ///   `usable` cold-start gate is enforced through `recovery(...)`.
    public static func recoveryTrace(hrv: Double,
                                     rhr: Double,
                                     resp: Double?,
                                     hrvBaseline: BaselineState,
                                     rhrBaseline: BaselineState?,
                                     respBaseline: BaselineState?,
                                     sleepPerf: Double?,
                                     skinTempDev: Double? = nil)
        -> (score: Double?, trace: [String]) {

        func r2(_ x: Double) -> Double { traceRound2(x) }

        var lines: [String] = []
        var nilTerms: [String] = []

        // #1988: the trace reads this baseline directly, so it must drop an unusable one as `recovery()` does, or it would list an rhr term the score did not use.
        let rhrB = rhrBaseline.flatMap { $0.usable ? $0 : nil }

        // The score the dashboard reads, verbatim.
        let score = recovery(hrv: hrv, rhr: rhr, resp: resp,
                             hrvBaseline: hrvBaseline, rhrBaseline: rhrB,
                             respBaseline: respBaseline, sleepPerf: sleepPerf,
                             skinTempDev: skinTempDev)

        // Cold-start gate: HRV baseline unusable -> recovery() returns nil before any term is built; report it and stop.
        guard hrvBaseline.usable else {
            lines.append("charge nilScore reason=hrvBaselineNotUsable "
                + "hrvStatus=\(hrvBaseline.status.rawValue) hrvNValid=\(hrvBaseline.nValid) "
                + "(need nValid>=\(Baselines.minNightsSeed))")
            return (score, lines)
        }

        // Per-driver baseline lines; skin-temp has no baseline (already a deviation).
        lines.append("charge baseline hrv mean=\(r2(hrvBaseline.baseline)) spread=\(r2(hrvBaseline.spread)) "
            + "nValid=\(hrvBaseline.nValid) status=\(hrvBaseline.status.rawValue)")
        if let b = rhrB {
            lines.append("charge baseline rhr mean=\(r2(b.baseline)) spread=\(r2(b.spread)) "
                + "nValid=\(b.nValid) status=\(b.status.rawValue)")
        }
        if let b = respBaseline {
            lines.append("charge baseline resp mean=\(r2(b.baseline)) spread=\(r2(b.spread)) "
                + "nValid=\(b.nValid) status=\(b.status.rawValue)")
        }

        // Per-term z x weight with the exact expressions and order `recovery(...)` uses, so the renormalization below matches.
        var terms: [(name: String, z: Double, w: Double)] = []

        // RHR z up front so the saturation guard can read the HRV<->RHR coupling before the HRV term is built; nil with no RHR baseline.
        let rhrZForGuard: Double? = rhrB.map { zScore($0.baseline, mean: rhr, spread: $0.spread) }

        // HRV term: higher is better, using the RAW z exactly as recovery() scores it (the saturation easing is reported
        // below but not applied). Weights/scales/centres also go through r2() so a future non-round weight renders
        // identically across platforms.
        let hrvZRaw = zScore(hrv, mean: hrvBaseline.baseline, spread: hrvBaseline.spread)
        let sat = parasympatheticSaturation(hrvZ: hrvZRaw, rhrZ: rhrZForGuard)
        terms.append(("hrv", hrvZRaw, wHRV))
        lines.append("charge term hrv z=\(r2(hrvZRaw)) w=\(r2(wHRV)) (higher HRV is better)")

        // RHR term: lower is better -> (mu - x) / sigma.
        if let z = rhrZForGuard {
            terms.append(("rhr", z, wRHR))
            lines.append("charge term rhr z=\(r2(z)) w=\(r2(wRHR)) (lower RHR is better)")
        } else {
            nilTerms.append("rhr")
        }

        // Resp term: lower is better; needs both the value and a baseline.
        if let r = resp, let b = respBaseline {
            let z = zScore(b.baseline, mean: r, spread: b.spread)
            terms.append(("resp", z, wResp))
            lines.append("charge term resp z=\(r2(z)) w=\(r2(wResp)) (lower resp is better)")
        } else {
            nilTerms.append("resp")
        }

        // Sleep-performance / Rest-quality term: no baseline, centered at sleepPerfCenter.
        if let sp = sleepPerf {
            let z = (sp - sleepPerfCenter) / sleepPerfScale
            terms.append(("sleepPerf", z, wSleep))
            lines.append("charge term sleepPerf z=\(r2(z)) w=\(r2(wSleep)) "
                + "(rest=\(r2(sp)) center=\(r2(sleepPerfCenter)))")
        } else {
            nilTerms.append("sleepPerf")
        }

        // Skin-temp term: symmetric penalty on |deviation|, only when supplied.
        if let dev = skinTempDev {
            let z = -abs(dev) / skinTempScaleC
            terms.append(("skinTempDev", z, wSkinTemp))
            lines.append("charge term skinTempDev z=\(r2(z)) w=\(r2(wSkinTemp)) "
                + "(dev=\(r2(dev))C penalty=-|dev|/\(r2(skinTempScaleC)))")
        } else {
            nilTerms.append("skinTempDev")
        }

        // The nil terms that dropped out and forced the weight renormalization.
        lines.append("charge nilTerm dropped=[\(nilTerms.joined(separator: ","))] "
            + "(each dropped term renormalizes the remaining weights)")

        // Total surviving weight and weighted composite z: the same math recovery(...) runs for the logistic input.
        let totalWeight = terms.reduce(0) { $0 + $1.w }
        let compositeZ = totalWeight > 0
            ? terms.reduce(0) { $0 + $1.z * $1.w } / totalWeight
            : 0.0
        lines.append("charge renorm totalWeight=\(r2(totalWeight)) compositeZ=\(r2(compositeZ)) "
            + "(z = sum(z*w)/sum(w))")

        // Final logistic score and band, read from recovery(...) verbatim.
        if let s = score {
            lines.append("charge score=\(r2(s)) band=\(band(s)) "
                + "(logistic k=\(r2(logisticK)) z0=\(r2(logisticZ0)))")
        } else {
            lines.append("charge nilScore reason=noValidTerms (no driver produced a usable term)")
        }

        // Parasympathetic-saturation guard: DETECTED, NOT APPLIED. Emitted only when the signature fires; the score
        // above is the unguarded number and this line reports the counterfactual (see the MARK header in
        // RecoveryScorer.swift for why the easing stays off). wouldRaiseCharge runs the eased composite through
        // logisticScore(...), the same curve recovery() uses, so the delta is exact.
        if sat.active, let s = score, totalWeight > 0 {
            let easedZ = terms.reduce(0) { $0 + ($1.name == "hrv" ? sat.easedHrvZ : $1.z) * $1.w } / totalWeight
            let wouldBe = logisticScore(compositeZ: easedZ)
            lines.append("charge saturation active hrvZraw=\(r2(hrvZRaw)) rhrZ=\(r2(rhrZForGuard ?? 0)) "
                + "damp=\(r2(sat.dampFraction)) wouldEaseHrvZTo=\(r2(sat.easedHrvZ)) "
                + "wouldRaiseCharge=\(r2(wouldBe - s)) wouldBand=\(band(wouldBe)) "
                + "(low HRV + low resting HR: candidate parasympathetic saturation. "
                + "Easing DETECTED ONLY, not applied: the score above is unchanged)")
        }

        return (score, lines)
    }
}
