import Foundation

// MARK: - Fusion value types (Local Multi-Device Fusion)
//
// Plain inputs/outputs for the pure fusion engine: no I/O, model or network. They mirror the
// `DailyMetricSource` / `SourcedDailyMetric` provenance vocabulary but cover every importer, so a
// new source is a table entry, not a type change.

/// Where a fused number came from: a superset of the legacy `DailyMetricSource`. The rawValue is
/// the canonical source id (`Repository.whoopSource` etc.) so it round-trips to the stored source string.
public enum FusionSource: String, Equatable, Sendable, CaseIterable, Codable {
    /// Imported WHOOP record (CSV/zip export under the strap's `deviceId`).
    case whoopImport = "my-whoop"
    /// Zoop-computed score derived on-device from the raw strap streams (the "$deviceId-zoop" sibling).
    case zoopComputed = "my-whoop-zoop"
    case appleHealth = "apple-health"
    case healthConnect = "health-connect"
    case xiaomiBand = "xiaomi-band"
    case nutritionCsv = "nutrition-csv"
    case localCache = "local-cache"

    /// Human-facing source name for a provenance pill ("from WHOOP"); never a clinical claim.
    public var displayName: String {
        switch self {
        case .whoopImport:   return "WHOOP"
        case .zoopComputed:  return "Zoop"
        case .appleHealth:   return "Apple Health"
        case .healthConnect: return "Health Connect"
        case .xiaomiBand:    return "Mi Band"
        case .nutritionCsv:  return "Nutrition"
        case .localCache:    return "Cached"
        }
    }
}

/// How well a metric agrees across the sources that reported it on the same day: `agree` is a quiet
/// parenthetical, `minorDelta` shows both, `conflict` is flagged and never merged. A deterministic
/// threshold output (see `MetricArbitrationPolicy.tolerance(metric:)`).
public enum AgreementState: String, Equatable, Sendable, CaseIterable, Codable {
    case single
    case agree
    /// Outside tolerance but inside the plausible-spread band: show both, no alarm.
    case minorDelta
    case conflict
}

/// One source's value for a `(metric, day)` with its policy trust tier. The winner is the lowest
/// `tier`, ties broken by `sourcePriority`. `reason` is the plain-English justification ("counts
/// directly", "best stager").
public struct ContributingSource: Equatable, Sendable {
    public let source: FusionSource
    public let value: Double
    public let tier: Int
    /// Stable tiebreak within a tier (lower wins).
    public let sourcePriority: Int
    /// The visible "best signal" reason for this source on this metric; never "accurate"/"correct".
    public let reason: String

    public init(source: FusionSource, value: Double, tier: Int, sourcePriority: Int, reason: String) {
        self.source = source
        self.value = value
        self.tier = tier
        self.sourcePriority = sourcePriority
        self.reason = reason
    }
}

/// The fused result for one `(metric, day)`: the winning value and source, every contributor (for
/// the compare sheet), and the agreement classification.
public struct FusedMetricPoint: Equatable, Sendable {
    public let metric: String
    /// The chosen value, verbatim from `winningSource`'s row (never an average).
    public let value: Double
    public let winningSource: FusionSource
    public let contributors: [ContributingSource]
    public let agreement: AgreementState

    public init(metric: String, value: Double, winningSource: FusionSource,
                contributors: [ContributingSource], agreement: AgreementState) {
        self.metric = metric
        self.value = value
        self.winningSource = winningSource
        self.contributors = contributors
        self.agreement = agreement
    }
}

/// A single source's raw input to the fusion engine; the Repository builds these so the engine stays pure.
public struct FusionInput: Equatable, Sendable {
    public let source: FusionSource
    public let value: Double
    public init(source: FusionSource, value: Double) {
        self.source = source
        self.value = value
    }
}
