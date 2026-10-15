import Foundation

// MARK: - FusionResolver (Local Multi-Device Fusion)
//
// Pure, deterministic, on-device fusion. Given per-source values for one (metric, day) it:
//   1. ranks sources by trust tier (MetricArbitrationPolicy), stable tiebreak, and picks the
//      winner's value verbatim (best signal wins, never an average);
//   2. cross-validates the others against the winner as single / agree / minorDelta / conflict
//      (conflicts are shown, not merged).
// No I/O: the Repository feeds it rows it already loads.
public enum FusionResolver {

    /// Resolves one metric for one day. `metricKey` is the resolver series key (e.g. "rhr", "steps")
    /// and picks tiers and tolerance via `MetricArbitrationPolicy`. Nil only when `inputs` is empty.
    ///
    /// The winner is the lowest-tier source, ties broken by `sourcePriority`; its value passes through
    /// unchanged. Agreement classifies how far the other sources sit from it.
    public static func resolve(metricKey: String, inputs: [FusionInput]) -> FusedMetricPoint? {
        guard !inputs.isEmpty else { return nil }
        let kind = MetricArbitrationPolicy.kind(forKey: metricKey)

        // A contributor per source, tagged with trust tier and reason.
        let contributorsUnsorted: [ContributingSource] = inputs.map { input in
            ContributingSource(
                source: input.source,
                value: input.value,
                tier: MetricArbitrationPolicy.tier(metric: kind, source: input.source),
                sourcePriority: MetricArbitrationPolicy.sourcePriority(input.source),
                reason: MetricArbitrationPolicy.reason(metric: kind, source: input.source)
            )
        }

        // Winner = lowest tier, then lowest source priority; a final index tiebreak keeps input order so
        // the result is deterministic across platforms.
        let ranked = contributorsUnsorted.enumerated().sorted { lhs, rhs in
            if lhs.element.tier != rhs.element.tier { return lhs.element.tier < rhs.element.tier }
            if lhs.element.sourcePriority != rhs.element.sourcePriority {
                return lhs.element.sourcePriority < rhs.element.sourcePriority
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }

        let winner = ranked[0]
        let agreement = classify(metric: kind, winningValue: winner.value, contributors: ranked)

        return FusedMetricPoint(
            metric: metricKey,
            value: winner.value,
            winningSource: winner.source,
            contributors: ranked,
            agreement: agreement
        )
    }

    /// Classifies how the non-winning sources agree with `winningValue`; the worst case wins (one
    /// conflicting source makes a conflict). One source gives `.single`. Public for Repository reuse.
    public static func classify(metric: MetricArbitrationPolicy.MetricKind,
                                winningValue: Double,
                                contributors: [ContributingSource]) -> AgreementState {
        // One source: nothing to compare against.
        guard contributors.count >= 2 else { return .single }

        let tol = MetricArbitrationPolicy.tolerance(metric: metric)
        var worst: AgreementState = .agree

        for c in contributors.dropFirst() {  // skip the winner (index 0)
            let delta = abs(c.value - winningValue)
            let agreeEdge: Double
            let minorEdge: Double
            if tol.isPercent {
                // The percentage band is relative to the winner's magnitude; with a zero winner, fall back to absolute deltas.
                let base = abs(winningValue)
                agreeEdge = tol.agree * base
                minorEdge = tol.minorDelta * base
            } else {
                agreeEdge = tol.agree
                minorEdge = tol.minorDelta
            }

            let state: AgreementState
            if delta <= agreeEdge {
                state = .agree
            } else if delta <= minorEdge {
                state = .minorDelta
            } else {
                state = .conflict
            }
            worst = worse(worst, state)
        }
        return worst
    }

    /// Severity order for the worst-case fold: agree < minorDelta < conflict (`single` never reaches here).
    private static func severity(_ s: AgreementState) -> Int {
        switch s {
        case .single:     return 0
        case .agree:      return 1
        case .minorDelta: return 2
        case .conflict:   return 3
        }
    }

    private static func worse(_ a: AgreementState, _ b: AgreementState) -> AgreementState {
        severity(a) >= severity(b) ? a : b
    }
}
