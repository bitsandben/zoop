import Foundation

// WatchRecovery: recovery/Charge from Apple Watch DAILY aggregates. The watch gives a few HRV SDNN
// readings a day plus a resting HR rather than dense overnight R-R, so this is a lower-density
// computation. No new formula: every term is relative to the person's OWN baseline, so the metric scale
// cancels (SDNN vs SDNN baseline behaves like RMSSD vs RMSSD baseline). Baselines are built through
// `Baselines` and fed into the SAME `RecoveryScorer.recovery(...)` the strap uses, so watch and strap
// land on the same 0-100 scale. Respiration, sleep-performance and skin-temp terms are not supplied, so
// RecoveryScorer renormalises the HRV + RHR weights.
//
// Honesty rule: nil recovery + `.calibrating` when today's SDNN is missing, the SDNN baseline is not
// usable, or the baseline accepted fewer than `minBaselineNights` nights. Never fabricate a number.
// Confidence comes from `ScoreConfidence.charge(recovery:hrvBaseline:)`, as for the strap.
public enum WatchRecovery {

    /// Result of a watch-recovery computation: the score (nil while calibrating) and its confidence tier.
    public struct Result: Equatable, Sendable {
        /// Recovery in [0, 100], or nil when we cannot honestly score yet.
        public let recovery: Double?
        /// Per-score confidence, driven by the real SDNN-baseline density.
        public let confidence: ScoreConfidence

        public init(recovery: Double?, confidence: ScoreConfidence) {
            self.recovery = recovery
            self.confidence = confidence
        }
    }

    /// Minimum VALID nights (accepted by the baseline, `BaselineState.nValid`, not raw history entries)
    /// before scoring from the watch. Deliberately above the baseline's seed gate
    /// (`Baselines.minNightsSeed` = 4): the watch's sparse SDNN deserves a longer warm-up.
    public static let minBaselineNights = 7

    /// Computes recovery/Charge from the watch's daily SDNN + resting HR vs the person's own baseline.
    ///
    /// - Parameters:
    ///   - todaySDNN: today's HRV SDNN (ms), or nil if the watch logged none.
    ///   - todayRHR: today's resting HR (bpm), or nil to drop the RHR term (also dropped without a usable RHR baseline).
    ///   - sdnnHistory: nightly SDNN values, oldest to newest.
    ///   - rhrHistory: nightly resting-HR values, oldest to newest.
    /// - Returns: recovery in [0,100] with a confidence tier, or nil + `.calibrating` when SDNN is missing,
    ///   the baseline is unusable, or history is thin.
    public static func compute(todaySDNN: Double?, todayRHR: Int?,
                               sdnnHistory: [Double], rhrHistory: [Double]) -> Result {
        // Baselines via the production model (Winsorized EWMA + cold-start gating), as the strap path does.
        let hrvBase = Baselines.foldHistory(sdnnHistory.map { Optional($0) }, cfg: Baselines.hrvCfg)
        let rhrBase = Baselines.foldHistory(rhrHistory.map { Optional($0) }, cfg: Baselines.restingHRCfg)

        // Same confidence helper as the strap Charge; it reads .calibrating whenever recovery would be nil.
        let conf = ScoreConfidence.charge(recovery: todaySDNN, hrvBaseline: hrvBase)

        // Honesty gate: today's SDNN, a usable baseline, AND at least a week of nights. The week counts
        // nights the baseline ACCEPTED (`nValid`): implausible readings are skip-and-held, so counting raw
        // entries would let rejected values buy a score early.
        guard let sdnn = todaySDNN,
              hrvBase.usable,
              hrvBase.nValid >= minBaselineNights else {
            return Result(recovery: nil, confidence: .calibrating)
        }

        // Reuse the canonical Charge engine; RecoveryScorer renormalises to HRV + RHR. The RHR term needs
        // today's reading AND a usable personal baseline: an empty or all-implausible history folds to
        // `foldHistory`'s synthetic midpoint (e.g. 75 bpm), nobody's resting HR. Same `usable ? state : nil`
        // gate as the strap Charge surfaces.
        let recovery = RecoveryScorer.recovery(
            hrv: sdnn,
            rhr: todayRHR.map(Double.init) ?? rhrBase.baseline,   // missing RHR → at-baseline (z≈0, neutral term)
            resp: nil,
            hrvBaseline: hrvBase,
            rhrBaseline: (todayRHR != nil && rhrBase.usable) ? rhrBase : nil,
            respBaseline: nil,
            sleepPerf: nil
        )

        // RecoveryScorer only returns nil on a cold-start HRV baseline (gated above); never coerce nil into a number.
        guard let recovery else {
            return Result(recovery: nil, confidence: .calibrating)
        }
        return Result(recovery: recovery, confidence: conf)
    }
}
