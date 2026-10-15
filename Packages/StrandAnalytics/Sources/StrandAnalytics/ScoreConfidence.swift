import Foundation
import WhoopStore

// Per-score certainty tier for Charge / Effort / Rest, so a sparse 5/MG day or cold-start baseline reads
// truthfully (shown as a small label/dot under each score; the score itself stays nil where it can't compute).
//
//   .calibrating - baseline/seed not usable or the core input window absent (no HR window for Effort, no in-bed
//                  data for Rest, HRV baseline unusable for Charge); any number shown is a placeholder.
//   .building    - usable but thin: provisional baseline or partial inputs (e.g. mostly PPG-derived HR).
//   .solid       - full inputs and a trusted baseline.
public enum ScoreConfidence: String, Equatable, Sendable, Codable {
    case calibrating
    case building
    case solid

    // MARK: - Derivations (one per score)

    /// Charge confidence: calibrating = no score (HRV baseline unusable); solid = score with a fully trusted HRV
    /// baseline; building = score with only a provisional baseline.
    public static func charge(recovery: Double?, hrvBaseline: BaselineState?) -> ScoreConfidence {
        guard recovery != nil, let b = hrvBaseline, b.usable else { return .calibrating }
        return b.trusted ? .solid : .building
    }

    /// Readiness confidence from the HRV/RHR baseline density: calibrating = no read; solid = full baseline window;
    /// building = shorter than the full window (e.g. 7-29 of 30).
    public static func readiness(hasRead: Bool, baselineNights: Int, fullWindow: Int) -> ScoreConfidence {
        guard hasRead else { return .calibrating }
        return baselineNights >= fullWindow ? .solid : .building
    }

    /// Effort confidence: calibrating = no usable HR window; solid = at least this many HR samples (~1 h at 1 Hz);
    /// building = thin window (PPG-backed / short day).
    public static let solidEffortReadings: Int = 3600  // ~1 h at 1 Hz of HR coverage
    public static func effort(strain: Double?, hrSampleCount: Int) -> ScoreConfidence {
        guard strain != nil else { return .calibrating }
        return hrSampleCount >= solidEffortReadings ? .solid : .building
    }

    /// Rest confidence: calibrating = no in-bed data; solid = session with staged sleep (restorative + efficiency
    /// real); building = stages/inputs partial.
    public static func rest(hasSession: Bool, hasStagedSleep: Bool) -> ScoreConfidence {
        guard hasSession else { return .calibrating }
        return hasStagedSleep ? .solid : .building
    }

    // MARK: - Stage low-confidence (restorative-share floor on a high-efficiency night)

    /// Restorative (deep+REM) share of asleep time below which staging is low-confidence on a high-efficiency night.
    /// A healthy adult night sits ~40-50%; near zero alongside high efficiency is more likely a staging miss (the
    /// EEG-free classifier's weakest link) than a real night, so flag low confidence rather than fake stages or tank Rest.
    public static let restorativeLowConfidenceShare: Double = 0.10

    /// Efficiency above which the restorative floor applies; a fragmented night legitimately has less deep/REM, so only the high-efficiency case is flagged.
    public static let highEfficiencyThreshold: Double = 0.85

    /// Rest confidence with the stage-quality, sparse-motion and hypnogram-coverage guards. Starts from
    /// `rest(hasSession:hasStagedSleep:)` and downgrades `.solid` to `.building` when any of:
    ///  - the night was staged on sparse gravity (`gravitySparse`): a WHOOP 4.0 offload night banks motion too coarsely
    ///    to reliably stage sleep (#345), even when staging manufactures high efficiency and restorative share (#319);
    ///  - efficiency is high yet the restorative share is below `restorativeLowConfidenceShare` (likely staging miss);
    ///  - `stageCoverage` shows the timeline covers less than `HypnogramCoverage.minCoverage` of its span: a
    ///    device-provided hypnogram assembled from incomplete records has ordinary stages over the part that arrived,
    ///    so the other guards stay quiet (a ring night covering 23% of 601 minutes was reported SOLID).
    /// `stageCoverage` nil (unknown/not applicable) fails open. `.calibrating`/`.building` pass through. Confidence only:
    /// never changes the Rest score or invents stages.
    public static func rest(hasSession: Bool, hasStagedSleep: Bool,
                            asleepSeconds: Double, restorativeSeconds: Double,
                            efficiency: Double, gravitySparse: Bool = false,
                            stageCoverage: Double? = nil) -> ScoreConfidence {
        let base = rest(hasSession: hasSession, hasStagedSleep: hasStagedSleep)
        if base != .solid { return base }
        if gravitySparse { return .building }   // #345: sparse-motion staging can't earn a SOLID Rest
        if let c = stageCoverage, c < HypnogramCoverage.minCoverage {
            return .building   // the timeline covers only part of the night it claims
        }
        if asleepSeconds <= 0 { return base }
        let restorativeShare = restorativeSeconds / asleepSeconds
        if efficiency >= highEfficiencyThreshold && restorativeShare < restorativeLowConfidenceShare {
            return .building   // high-efficiency night with near-zero deep+REM → low-confidence staging (#H9)
        }
        return base
    }
}
