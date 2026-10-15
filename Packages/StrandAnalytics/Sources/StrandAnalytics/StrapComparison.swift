import Foundation

// StrapComparison: a read-only, non-diagnostic comparison of the SAME metric from two straps (#1300 tier 2).
// Reuses `MetricArbitrationPolicy.tolerance` to say whether the straps agree, differ a little, or conflict.
// It never mixes the two into one score (scores stay single-owner-per-day, invariant I2). Pure.
public enum StrapComparison {

    /// One metric's two-strap comparison; nil `a`/`b` means that strap has no value, `.single` when only one reported.
    public struct Row: Equatable, Sendable {
        public let metric: MetricArbitrationPolicy.MetricKind
        public let a: Double?
        public let b: Double?
        public let agreement: AgreementState
        public init(metric: MetricArbitrationPolicy.MetricKind, a: Double?, b: Double?, agreement: AgreementState) {
            self.metric = metric
            self.a = a
            self.b = b
            self.agreement = agreement
        }
    }

    /// Compares two straps' per-metric values. Emits a row per metric either strap reported, in `MetricKind`
    /// declaration order; `.other` (the non-comparable passthrough family) is skipped.
    public static func compare(_ a: [MetricArbitrationPolicy.MetricKind: Double],
                               _ b: [MetricArbitrationPolicy.MetricKind: Double]) -> [Row] {
        MetricArbitrationPolicy.MetricKind.allCases.compactMap { metric in
            guard metric != .other else { return nil }
            let va = a[metric], vb = b[metric]
            guard va != nil || vb != nil else { return nil }
            return Row(metric: metric, a: va, b: vb, agreement: agreement(metric: metric, a: va, b: vb))
        }
    }

    /// Agreement between two strap values for one metric using its published tolerance; `.single` when only
    /// one has it. Symmetric: a percentage tolerance is taken against the LARGER magnitude.
    public static func agreement(metric: MetricArbitrationPolicy.MetricKind,
                                 a: Double?, b: Double?) -> AgreementState {
        guard let a, let b else { return .single }
        let tol = MetricArbitrationPolicy.tolerance(metric: metric)
        let delta = abs(a - b)
        let base = max(abs(a), abs(b))
        let agreeEdge = tol.isPercent ? tol.agree * base : tol.agree
        let minorEdge = tol.isPercent ? tol.minorDelta * base : tol.minorDelta
        if delta <= agreeEdge { return .agree }
        if delta <= minorEdge { return .minorDelta }
        return .conflict
    }
}
