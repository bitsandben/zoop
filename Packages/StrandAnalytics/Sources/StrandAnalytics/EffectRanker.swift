import Foundation

// EffectRanker.swift - the unified, lag-aware "what moves your Charge" ranker.
//
// Pure, DB-free. Generalises ActivityCostEngine's single-sport D+1 to every logged journal
// behaviour against every daily outcome over a small fixed lag set, so "same day" can be told
// from "shows up the next morning". For each (behaviour b, outcome o, lag L in {0, 1, 2}):
//   1. behaviourDays = days b was logged (dose >= 1).
//   2. Pair behaviour day D with outcome day D+L by re-keying outcome[D+L] under D
//      (CorrelationEngine.shiftDay(day, by: -L)).
//   3. Run BehaviorInsights.effect on the shifted map (means, delta, Cohen's d, Welch p,
//      significant at min(nWith, nWithout) >= 5).
//   4. Keep per (b, o) the lag with the largest |cohensD| among lags that cleared the group gate.
//
// Effect size, n and a ScoreConfidence tier lead, never a bare "significant" stamp. The lag set is
// capped so the comparison count stays bounded, and nothing claims a behaviour "causes" anything.
// Rows rank like BehaviorInsights.rank (significant first, |cohensD| desc, stable tiebreak).

// MARK: - Result

/// One ranked, lag-aware behaviour-to-outcome effect: the best lag's BehaviorEffect, the lag it was
/// found at, and a confidence tier from the paired-day count.
public struct RankedEffect: Equatable, Sendable {
    public let behavior: String
    public let outcome: String
    /// The lag in days of the strongest honest effect: 0 = same day, 1 = next morning, 2 = two mornings later.
    public let lag: Int
    public let effect: BehaviorEffect
    public let confidence: ScoreConfidence

    public init(behavior: String, outcome: String, lag: Int,
                effect: BehaviorEffect, confidence: ScoreConfidence) {
        self.behavior = behavior
        self.outcome = outcome
        self.lag = lag
        self.effect = effect
        self.confidence = confidence
    }

    /// Plain-English lead/lag text, e.g. "same day" / "next morning" / "2 mornings later".
    public var leadLagText: String {
        switch lag {
        case 0: return "same day"
        case 1: return "next morning"
        default: return "\(lag) mornings later"
        }
    }

    /// The sign-aware sentence, reusing BehaviorInsights' renderer plus the lead/lag clause.
    public func sentence() -> String {
        let base = BehaviorInsights.sentence(effect)
        // Drop the trailing period, append the lead/lag, restore it.
        let trimmed = base.hasSuffix(".") ? String(base.dropLast()) : base
        return "\(trimmed) (\(leadLagText))."
    }
}

// MARK: - Engine

public enum EffectRanker {

    /// The fixed lag set searched per (behaviour, outcome); small and explicit (not a fitted VAR) so the
    /// multiple-comparison count stays bounded.
    public static let lagSet: [Int] = [0, 1, 2]

    /// Paired-day count below which confidence is `.calibrating`; equals BehaviorInsights' group gate.
    public static let calibratingBelow: Int = BehaviorInsights.minGroupForSignificance  // 5
    /// Paired-day count at/above which confidence is `.solid` (else `.building`).
    public static let solidPairs: Int = 10

    // MARK: - Rank

    /// Ranks every behaviour against one outcome across the lag set, keeping each behaviour's best lag.
    ///
    /// - Parameters:
    ///   - behaviors: per behaviour name, the set of "yyyy-MM-dd" days it was logged (dose >= 1).
    ///   - outcomeByDay: the daily outcome series keyed "yyyy-MM-dd".
    ///   - outcome: the label carried onto each RankedEffect.
    /// - Returns: one RankedEffect per behaviour with a usable lag, significant first, |cohensD| desc,
    ///   then name asc.
    public static func rank(behaviors: [String: Set<String>],
                            controls: [String: Set<String>],
                            outcomeByDay: [String: Double],
                            outcome: String) -> [RankedEffect] {
        var rows: [RankedEffect] = []
        // Sorted names keep the build order deterministic.
        for name in behaviors.keys.sorted() {
            let days = behaviors[name]!
            // Absent from `controls` means no control group and yields nothing (see BehaviorInsights.effect):
            // failing closed beats measuring against every unlogged day.
            if let row = bestLag(behaviorDays: days, controlDays: controls[name] ?? [],
                                 outcomeByDay: outcomeByDay,
                                 behavior: name, outcome: outcome) {
                rows.append(row)
            }
        }
        return sorted(rows)
    }

    /// The best-lag RankedEffect for one behaviour against one outcome, or nil when no lag yields a
    /// computable effect that clears the group gate.
    public static func bestLag(behaviorDays: Set<String>,
                               controlDays: Set<String>,
                               outcomeByDay: [String: Double],
                               behavior: String,
                               outcome: String) -> RankedEffect? {
        var best: (lag: Int, effect: BehaviorEffect)?
        for lag in lagSet {
            let shifted = shiftedOutcome(outcomeByDay, byLag: lag)
            guard let e = BehaviorInsights.effect(behaviorDays: behaviorDays,
                                                  controlDays: controlDays,
                                                  outcomeByDay: shifted,
                                                  behavior: behavior,
                                                  outcome: outcome) else { continue }
            // Group gate: both sides must clear the significance minimum so a lag can't win on a fluke.
            guard Swift.min(e.nWith, e.nWithout) >= BehaviorInsights.minGroupForSignificance else { continue }

            if let cur = best {
                // Largest |cohensD| wins; ties go to the smaller lag.
                let better = abs(e.cohensD) > abs(cur.effect.cohensD)
                    || (abs(e.cohensD) == abs(cur.effect.cohensD) && lag < cur.lag)
                if better { best = (lag, e) }
            } else {
                best = (lag, e)
            }
        }
        guard let chosen = best else { return nil }
        let pairs = Swift.min(chosen.effect.nWith, chosen.effect.nWithout)
        return RankedEffect(behavior: behavior, outcome: outcome, lag: chosen.lag,
                            effect: chosen.effect, confidence: confidence(forPairs: pairs))
    }

    // MARK: - Lag alignment

    /// Re-keys the outcome series so behaviour day D pairs with the outcome `lag` days later:
    /// out'[D] = out[D+lag], by shifting each key backward by `lag`. `lag == 0` is the identity.
    static func shiftedOutcome(_ outcomeByDay: [String: Double], byLag lag: Int) -> [String: Double] {
        if lag == 0 { return outcomeByDay }
        var out: [String: Double] = [:]
        out.reserveCapacity(outcomeByDay.count)
        for (day, value) in outcomeByDay {
            // The outcome on `day` belongs to behaviour day `day - lag`.
            if let behaviourKey = CorrelationEngine.shiftDay(day, by: -lag) {
                out[behaviourKey] = value
            }
        }
        return out
    }

    // MARK: - Confidence

    /// Confidence from the smaller group's paired-day count: below the gate `.calibrating`, below
    /// solidPairs `.building`, else `.solid`.
    static func confidence(forPairs pairs: Int) -> ScoreConfidence {
        if pairs < calibratingBelow { return .calibrating }
        return pairs >= solidPairs ? .solid : .building
    }

    // MARK: - Ranking

    /// Stable rank matching BehaviorInsights.rank: significant first, |cohensD| desc, then name ascending.
    static func sorted(_ rows: [RankedEffect]) -> [RankedEffect] {
        rows.sorted { a, b in
            if a.effect.significant != b.effect.significant { return a.effect.significant }
            let la = abs(a.effect.cohensD), lb = abs(b.effect.cohensD)
            if la != lb { return la > lb }
            return a.behavior < b.behavior
        }
    }
}
