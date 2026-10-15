#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - BodyFinding (CONCEPT §1.1 metric anatomy, for readings that are not a single vital)
//
// An interpretation ("Your HRV has been below your normal for 5 days") or a pattern ("On days with
// alcohol, recovery was 9 % lower") carries the same anatomy as a metric: a value, what it is compared
// with, a verdict word from a closed set, one sentence of meaning, the sample it rests on, and an
// explainer with method, data used and confidence. Built by `BodyFindings` / `BodyPatterns`; views
// only render it.

struct BodyFinding: Identifiable, Equatable {
    let id: String
    let title: LocalizedStringResource
    /// The interpretation itself, one sentence. Leads the card.
    let meaning: LocalizedStringResource
    /// The number, already formatted for the app locale ("−12 %", "2 days", "21:00").
    let value: String
    /// What the value is measured against ("vs. your normal of the 30 days before").
    let comparison: LocalizedStringResource
    let verdict: BodyVerdict
    /// The sample the reading rests on ("14 days with · 20 without").
    let sample: LocalizedStringResource
    let explanation: BodyFindingExplanation
    let visual: BodyFindingVisual?
}

/// Closed verdict vocabulary for findings and patterns. Vital-style words reuse the metric catalogue
/// entries so "Below your range" reads the same everywhere.
enum BodyVerdict: Equatable {
    case typical, above, below
    /// A range verdict with direction (HRV up, resting heart rate down = better), as on the metric tiles.
    case better, worse
    case strong, noticeable, little
    case quick, slow
    case mostlyEasy, mixed, mostlyHard
    case clearPattern, weakPattern
    case clearDifference, noClearDifference

    /// Attention verdicts get the warning tint; everything else stays neutral (§1 "calm by default").
    var needsAttention: Bool { self == .strong || self == .slow || self == .worse }

    var text: LocalizedStringResource {
        switch self {
        case .typical: return MetricVerdict.typical.text
        case .above: return MetricVerdict.above.text
        case .below: return MetricVerdict.below.text
        case .better: return MetricVerdict.above.text(rangeIsPersonal: true, polarity: .higherIsBetter)
        case .worse: return MetricVerdict.below.text(rangeIsPersonal: true, polarity: .higherIsBetter)
        case .strong: return BodyStrings.verdictStrong
        case .noticeable: return BodyStrings.verdictNoticeable
        case .little: return BodyStrings.verdictLittle
        case .quick: return BodyStrings.verdictQuick
        case .slow: return BodyStrings.verdictSlow
        case .mostlyEasy: return BodyStrings.verdictMostlyEasy
        case .mixed: return BodyStrings.verdictMixed
        case .mostlyHard: return BodyStrings.verdictMostlyHard
        case .clearPattern: return BodyStrings.verdictClearPattern
        case .weakPattern: return BodyStrings.verdictWeakPattern
        case .clearDifference: return BodyStrings.verdictClearDifference
        case .noClearDifference: return BodyStrings.verdictNoClearDifference
        }
    }
}

/// The explainer behind a finding: what it is, how it is computed, which data went in, how sure it is.
struct BodyFindingExplanation: Equatable {
    enum Confidence: Equatable {
        case building, solid

        /// Below `solidAt` samples a reading is still building; the engines already refuse thinner data.
        static func confidence(samples: Int, solidAt: Int) -> Confidence {
            samples >= solidAt ? .solid : .building
        }
    }

    let whatItIs: LocalizedStringResource
    let methodName: LocalizedStringResource
    let methodSummary: LocalizedStringResource
    /// Literature reference, not translated.
    let citation: String?
    let dataUsed: LocalizedStringResource
    let confidence: Confidence
    let confidenceReason: LocalizedStringResource
}

/// The chart a finding's explainer draws. Every case carries what the axes need to be labelled.
enum BodyFindingVisual: Equatable {
    /// Daily values against the normal band (mean ± spread). `unit` labels the y axis.
    case line(points: [MetricExplanation.TrendPoint], normal: Double, spread: Double, unit: MetricUnit)
    /// Mean recovery per ISO weekday (1 = Monday); highlighted days stood out.
    case weekdays(means: [Int: Double], low: Int?, high: Int?)
    /// Recovery gap to normal on the days after a hard day (index 0 = the hard day).
    case trajectory([Double?])
    /// Zone minutes, zones 1–5.
    case zones([Double])
    /// Mean stress level per hour of day (0–3).
    case hours([BodyInsights.HourLevel], peak: Int, calm: Int)
    /// Effort (on the displayed scale) against next-morning recovery, with the fitted slope.
    case scatter(points: [BodyInsights.StrainSensitivity.Pair], slope: Double)
    /// Two group means side by side ("with" vs "without", "calm" vs "stressful").
    case groups(first: Double, second: Double, firstLabel: LocalizedStringResource,
                secondLabel: LocalizedStringResource, unit: MetricUnit)
}
#endif
