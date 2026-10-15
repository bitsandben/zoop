import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Explainer content (CONCEPT §1.1)
//
// The sheet behind the hero and behind each contributor row. The hero's explainer carries no trend and
// no contributor list: the screen already shows both right below it, and a fact appears once.

enum RecoveryExplanations {

    static func hero(confidence: ScoreConfidence, hrvNights: Int, window: DateInterval?) -> MetricExplanation {
        let reason: LocalizedStringResource
        switch confidence {
        case .solid:
            reason = RecoveryStrings.confidenceSolid(hrvNights)
        case .building:
            reason = RecoveryStrings.confidenceBuilding(hrvNights, of: Baselines.minNightsTrust)
        case .calibrating:
            reason = RecoveryStrings.confidenceCalibrating(max(Baselines.minNightsSeed - hrvNights, 1))
        }
        return MetricExplanation(
            whatItIs: RecoveryStrings.heroWhatItIs,
            method: .init(name: RecoveryStrings.heroMethodName,
                          summary: RecoveryStrings.heroMethodSummary,
                          // HRV-guided practice: ln rMSSD against the personal range (CONCEPT §5.1).
                          citation: "Plews et al., 2012; Kiviniemi et al., 2007"),
            dataUsed: .init(count: .nights(hrvNights), window: window),
            confidenceReason: reason)
    }

    /// `share` is this term's whole-percent share of the weights that fed the score, so it moves with
    /// the user's check-in calibration instead of quoting the standard weights.
    static func contributor(kind: RecoveryContributor.Kind, share: Int, nights: Int,
                            trend: [MetricExplanation.TrendPoint], window: DateInterval?) -> MetricExplanation {
        MetricExplanation(
            whatItIs: RecoveryStrings.whatItIs(kind),
            method: .init(name: RecoveryStrings.contributorMethodName,
                          summary: RecoveryStrings.contributorMethodSummary(share: share),
                          citation: kind == .hrv ? "Plews et al., 2012" : nil),
            dataUsed: .init(count: .nights(nights), window: window),
            trend: trend)
    }
}
