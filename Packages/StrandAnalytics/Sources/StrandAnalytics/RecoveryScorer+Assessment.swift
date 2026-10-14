import Foundation

public extension RecoveryScorer {

    /// Why a Recovery reads the way it does.
    enum Reason: String, Equatable, Sendable {
        /// Scored against a usable HRV baseline.
        case scored
        /// The HRV baseline has fewer than `Baselines.minNightsSeed` valid nights, so no score yet.
        case calibrating
        /// The baseline is usable but the night lacked a required input (HRV or resting HR).
        case missingInputs
    }

    /// Wraps a score produced by `recovery(...)` with its confidence and reason.
    ///
    /// Takes the score rather than recomputing it so this can never disagree with the number written
    /// for the day: `recovery(...)` stays the only place the composite is computed.
    static func assessment(score: Double?, hrvBaseline: BaselineState?) -> Assessment<Double, Reason> {
        let confidence = ScoreConfidence.charge(recovery: score, hrvBaseline: hrvBaseline)
        let reason: Reason
        if score != nil {
            reason = .scored
        } else if let b = hrvBaseline, b.usable {
            reason = .missingInputs
        } else {
            reason = .calibrating
        }
        return Assessment(value: score, confidence: confidence, reason: reason)
    }
}
