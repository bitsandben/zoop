import Foundation

public extension RecoveryScorer {

    /// Why a Recovery reads the way it does.
    enum Reason: String, Equatable, Sendable {
        case scored
        /// Fewer than `Baselines.minNightsSeed` valid HRV baseline nights: no score yet.
        case calibrating
        /// Baseline usable but the night lacked HRV or resting HR.
        case missingInputs
    }

    /// Wraps a score from `recovery(...)` with its confidence and reason. Takes the score rather than recomputing it,
    /// so it can never disagree with the number written for the day.
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
