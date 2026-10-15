import Foundation

// MARK: - MetricArbitrationPolicy (local multi-device fusion)
//
// A data table keyed by metric x source that yields a trust tier, a plain published reason string and the
// per-metric cross-validation tolerances; the single place a new source is registered. Pure constants and lookups.
//
// Trust tiers (lower = more trusted), by what a device measures vs estimates:
//   0 - direct dedicated sensor (WHOOP R-R for HRV, a wrist band's pedometer for steps, chest/PPG strap for HR,
//       ring/strap temp for skin temp)
//   1 - derived on-device by Zoop from raw streams (recovery/strain/sleep)
//   2 - phone aggregate (Apple Health / Health Connect) of a declared-compatible quantity
//   3 - estimate / proxy (a strap's step estimate, a calories estimate)
// "Best signal" always has a named, visible reason, never "accurate"/"clinical": wellness transparency only.
public enum MetricArbitrationPolicy {

    /// Canonical fusion metric families. Resolver series keys map onto one for tiering; unmapped keys fall to `.other` (single-source passthrough, tiered by source kind).
    public enum MetricKind: String, Equatable, Sendable, CaseIterable {
        case restingHR
        case heartRate      // avg/max HR
        case hrv
        case spo2
        case skinTemp
        case steps
        case sleep          // any sleep stage/total
        case calories
        case other
    }

    /// Maps a resolver series key onto a `MetricKind` (same vocabulary as `Repository.appleCompatibleKey`).
    public static func kind(forKey key: String) -> MetricKind {
        switch key {
        case "rhr", "resting_hr":
            return .restingHR
        case "avg_hr", "max_hr":
            return .heartRate
        case "hrv":
            return .hrv
        case "spo2":
            return .spo2
        case "skin_temp", "skinTemp":
            return .skinTemp
        case "steps":
            return .steps
        case "sleep_total_min", "asleep_min",
             "sleep_deep_min", "deep_min",
             "sleep_rem_min", "rem_min",
             "sleep_light_min", "core_min",
             "in_bed_min":
            return .sleep
        case "active_kcal", "energy_kcal":
            return .calories
        default:
            return .other
        }
    }

    /// Trust tier for a `(metric, source)` pair, lower = more trusted. E.g. a wrist band's pedometer (0) beats the
    /// strap's step estimate (3); WHOOP sleep stages (0) beat phone sleep buckets (2). Unmapped keys tier by source kind.
    public static func tier(metric: MetricKind, source: FusionSource) -> Int {
        switch metric {
        case .restingHR, .heartRate, .hrv, .spo2:
            // Worn-sensor vitals: strap measures, phone aggregates.
            switch source {
            case .whoopImport:   return 0   // direct dedicated sensor (R-R / PPG)
            case .xiaomiBand:    return 0   // dedicated wrist PPG
            case .zoopComputed:  return 1   // derived on-device from raw strap streams
            case .appleHealth:   return 2   // phone aggregate
            case .healthConnect: return 2
            case .nutritionCsv:  return 3
            case .localCache:    return 3
            }

        case .skinTemp:
            // Redundancy metric: strap/ring measures it, phone rarely carries it.
            switch source {
            case .whoopImport:   return 0
            case .xiaomiBand:    return 0
            case .zoopComputed:  return 1
            case .appleHealth:   return 2
            case .healthConnect: return 2
            case .nutritionCsv:  return 3
            case .localCache:    return 3
            }

        case .steps:
            // The device that actually counts steps wins; the strap only estimates from motion.
            switch source {
            case .xiaomiBand:    return 0   // wrist pedometer — counts directly
            case .appleHealth:   return 0   // phone pedometer — counts directly
            case .healthConnect: return 0
            case .whoopImport:   return 3   // strap step estimate is a last resort
            case .zoopComputed:  return 3   // Zoop step estimate from motion
            case .nutritionCsv:  return 3
            case .localCache:    return 3
            }

        case .sleep:
            // Best stager wins: imported WHOOP > Zoop-computed > phone buckets.
            switch source {
            case .whoopImport:   return 0
            case .zoopComputed:  return 1
            case .xiaomiBand:    return 1   // a band with its own staging, below WHOOP's
            case .appleHealth:   return 2   // phone sleep buckets
            case .healthConnect: return 2
            case .nutritionCsv:  return 3
            case .localCache:    return 3
            }

        case .calories:
            // Active energy is an estimate everywhere; phone aggregate slightly over a strap estimate.
            switch source {
            case .appleHealth:   return 2
            case .healthConnect: return 2
            case .whoopImport:   return 3
            case .zoopComputed:  return 3
            case .xiaomiBand:    return 3
            case .nutritionCsv:  return 3
            case .localCache:    return 3
            }

        case .other:
            // Unmapped keys: tier by source kind only.
            switch source {
            case .whoopImport:   return 0
            case .xiaomiBand:    return 0
            case .zoopComputed:  return 1
            case .appleHealth:   return 2
            case .healthConnect: return 2
            case .nutritionCsv:  return 0   // its own single-source metric
            case .localCache:    return 3
            }
        }
    }

    /// Deterministic tiebreak within a tier (lower wins): imported WHOOP, Zoop-computed, phone (Apple before Health
    /// Connect, #443), dedicated band, single-source, cache.
    public static func sourcePriority(_ source: FusionSource) -> Int {
        switch source {
        case .whoopImport:   return 0
        case .zoopComputed:  return 1
        case .appleHealth:   return 2
        case .healthConnect: return 3
        case .xiaomiBand:    return 4
        case .nutritionCsv:  return 5
        case .localCache:    return 6
        }
    }

    /// The published plain-English "best signal" reason for a source on a metric (wellness-only; drives the fused row caption).
    public static func reason(metric: MetricKind, source: FusionSource) -> String {
        let t = tier(metric: metric, source: source)
        switch (metric, source) {
        case (.steps, .xiaomiBand), (.steps, .appleHealth), (.steps, .healthConnect):
            return "counts directly"
        case (.steps, .whoopImport), (.steps, .zoopComputed):
            return "step estimate"
        case (.sleep, .whoopImport):
            return "best stager"
        case (.sleep, .zoopComputed):
            return "computed stages"
        case (.sleep, .appleHealth), (.sleep, .healthConnect):
            return "phone sleep buckets"
        case (.skinTemp, _):
            return "worn sensor"
        default:
            switch t {
            case 0: return "direct sensor"
            case 1: return "computed on device"
            case 2: return "phone aggregate"
            default: return "estimate"
            }
        }
    }

    // MARK: - Cross-validation tolerances
    //
    // Hand-set bands for the agreement classifier: a delta inside `agree` agrees, inside `minorDelta` is plausible
    // spread (show both), beyond is a `conflict` (flag, never merge). `Tolerance` carries a percentage band (steps)
    // or absolute band, per `isPercent`.

    public struct Tolerance: Equatable, Sendable {
        /// Within this delta of the winning value: `agree`.
        public let agree: Double
        /// Within this delta (beyond `agree`): `minorDelta`; beyond it: `conflict`.
        public let minorDelta: Double
        /// When true the deltas are fractions of the winning value (0.10 = 10%), else absolute.
        public let isPercent: Bool

        public init(agree: Double, minorDelta: Double, isPercent: Bool) {
            self.agree = agree
            self.minorDelta = minorDelta
            self.isPercent = isPercent
        }
    }

    /// Tolerance band for a metric. Defaults: RHR +/-3 bpm, asleep +/-20 min, steps +/-10%.
    public static func tolerance(metric: MetricKind) -> Tolerance {
        switch metric {
        case .restingHR:
            return Tolerance(agree: 3, minorDelta: 8, isPercent: false)      // bpm
        case .heartRate:
            return Tolerance(agree: 5, minorDelta: 12, isPercent: false)     // bpm
        case .hrv:
            return Tolerance(agree: 8, minorDelta: 20, isPercent: false)     // ms
        case .spo2:
            return Tolerance(agree: 2, minorDelta: 4, isPercent: false)      // %
        case .skinTemp:
            return Tolerance(agree: 0.5, minorDelta: 1.5, isPercent: false)  // °C
        case .steps:
            return Tolerance(agree: 0.10, minorDelta: 0.30, isPercent: true) // ±10% / ±30%
        case .sleep:
            return Tolerance(agree: 20, minorDelta: 60, isPercent: false)    // min
        case .calories:
            return Tolerance(agree: 0.15, minorDelta: 0.40, isPercent: true) // ±15% / ±40%
        case .other:
            return Tolerance(agree: 0.10, minorDelta: 0.30, isPercent: true)
        }
    }

    /// Tolerance for a raw resolver key (via `kind(forKey:)`).
    public static func tolerance(forKey key: String) -> Tolerance {
        tolerance(metric: kind(forKey: key))
    }
}
