import Foundation

// DoseResponsePriors.swift - the documented, conservative population priors that the per-user
// dose-response fit shrinks toward until enough nights are logged.
//
// Pure data plus a lookup. Deliberately modest, labelled "typical patterns, not yours", never
// learned from any user. Each prior is an effect per incremental unit of dose on a named outcome:
//   - Alcohol to Charge (0-100): roughly -X points per extra drink.
//   - Caffeine to HRV (ms): roughly -X ms per step later in the day (a timing bucket, not mg).
// Wellness association, never a causal or clinical claim.

/// Identifies a dosed behaviour with a documented population prior. The raw string is the stable lookup key.
public enum DosedBehavior: String, Equatable, Sendable, Codable, CaseIterable {
    /// Alcoholic drinks, dose = number of drinks (0/1/2/3+).
    case alcohol
    /// Caffeine, dose = a time-of-day bucket (morning/midday/after-2pm/evening = 0..3), later = stronger; not mg.
    case caffeine
}

/// A documented population prior: the typical per-unit effect of a dosed behaviour on one outcome,
/// with a clamp range so extrapolation can never escape it.
public struct DoseResponsePrior: Equatable, Sendable {
    public let behavior: DosedBehavior
    public let outcome: String
    /// Typical signed effect per one extra unit of dose; negative = the outcome typically sits lower.
    public let slopePerUnit: Double
    public let clampLow: Double
    public let clampHigh: Double

    public init(behavior: DosedBehavior, outcome: String, slopePerUnit: Double,
                clampLow: Double, clampHigh: Double) {
        self.behavior = behavior
        self.outcome = outcome
        self.slopePerUnit = slopePerUnit
        self.clampLow = clampLow
        self.clampHigh = clampHigh
    }
}

public enum DoseResponsePriors {

    /// The outcome each behaviour's headline prior is expressed in: Charge for alcohol, HRV for caffeine.
    public static func defaultOutcome(for behavior: DosedBehavior) -> String {
        switch behavior {
        case .alcohol: return "Charge"
        case .caffeine: return "HRV"
        }
    }

    /// The documented priors, kept small and explicit; always overridable by the user's own data.
    ///
    /// - Alcohol to Charge: about -5 points per extra drink (clamped -15...+2).
    /// - Caffeine to HRV: about -4 ms per step later in the day (clamped -20...+4).
    static let table: [DoseResponsePrior] = [
        DoseResponsePrior(behavior: .alcohol, outcome: "Charge",
                          slopePerUnit: -5.0, clampLow: -15.0, clampHigh: 2.0),
        DoseResponsePrior(behavior: .caffeine, outcome: "HRV",
                          slopePerUnit: -4.0, clampLow: -20.0, clampHigh: 4.0),
    ]

    /// Looks up the prior for a `(behaviour, outcome)` pair, or nil if none is documented.
    public static func prior(for behavior: DosedBehavior, outcome: String) -> DoseResponsePrior? {
        table.first { $0.behavior == behavior && $0.outcome == outcome }
    }

    /// The prior for a behaviour's default headline outcome.
    public static func prior(for behavior: DosedBehavior) -> DoseResponsePrior? {
        prior(for: behavior, outcome: defaultOutcome(for: behavior))
    }
}
