import Foundation

// MARK: - The muscle-group vocabulary (v45)
//
// Exercise names are free text; muscle GROUPS are a closed set of canonical tokens so a per-muscle rollup
// always lands in the same bucket.
//
// The raw values are a STORED-DATA CONTRACT (written into `liftExercise` and `liftSet` primary/secondary
// muscle columns, byte-identical on Android):
//   - NEVER rename or remove a case; stored rows would stop resolving. Adding a case is safe.
//   - Tokens are locale-independent; display names are localized in the app layer.
//
// Granularity matches what the volume literature measures (pectoralis, lats, deltoid heads, biceps, triceps,
// quads, hamstrings, glutes, erectors, calves) plus a few trained-but-rarely-studied groups. There is
// deliberately no "full body" or "other": they would contribute to no muscle's count while looking like
// they did. An unclassified exercise has a nil primary: it still counts toward volume and session load.

/// A muscle group a set can be attributed to. Raw values are stored; do not rename them.
public enum LiftMuscle: String, CaseIterable, Codable, Sendable {

    // Push
    case chest
    case frontDelts
    case sideDelts
    case rearDelts
    case triceps

    // Pull
    case lats
    case upperBack
    case traps
    case biceps
    case forearms

    // Legs
    case quads
    case hamstrings
    case glutes
    case adductors
    case abductors
    case calves

    // Trunk
    case abs
    case obliques
    case lowerBack
    case neck

    /// Coarse section used only to group the picker. Not stored or counted.
    public enum Region: String, CaseIterable, Sendable {
        case push, pull, legs, trunk
    }

    public var region: Region {
        switch self {
        case .chest, .frontDelts, .sideDelts, .rearDelts, .triceps:
            return .push
        case .lats, .upperBack, .traps, .biceps, .forearms:
            return .pull
        case .quads, .hamstrings, .glutes, .adductors, .abductors, .calves:
            return .legs
        case .abs, .obliques, .lowerBack, .neck:
            return .trunk
        }
    }

    /// Cases in picker order: by region, in the order declared above.
    public static var ordered: [LiftMuscle] { allCases }

    /// Cases in one region, in declaration order.
    public static func inRegion(_ region: Region) -> [LiftMuscle] {
        allCases.filter { $0.region == region }
    }

    /// What one set contributes to this muscle's weekly count. The 2025 Sports Medicine dose-response
    /// meta-regression found fractional counting (indirect mover = 0.5 set) best supported, and the reference
    /// doses Zoop shows are derived under it, so the two must change together.
    public static let directSetCredit: Double = 1.0
    public static let indirectSetCredit: Double = 0.5

    // MARK: - The secondary-muscle list, as stored
    //
    // A comma-joined token list in one TEXT column (short, never queried alone). Order is preserved; duplicates
    // and the primary itself are stripped on encode so a set is never counted twice for one muscle.

    /// Encodes a secondary list for storage. Returns nil for an empty list so the column stays NULL.
    public static func encodeList(_ muscles: [LiftMuscle], excluding primary: LiftMuscle? = nil) -> String? {
        var seen = Set<LiftMuscle>()
        if let primary { seen.insert(primary) }
        var kept: [LiftMuscle] = []
        for m in muscles where !seen.contains(m) {
            seen.insert(m)
            kept.append(m)
        }
        return kept.isEmpty ? nil : kept.map(\.rawValue).joined(separator: ",")
    }

    /// Decodes a stored secondary list. Unknown tokens are skipped so a newer database stays readable by an older build.
    public static func decodeList(_ stored: String?) -> [LiftMuscle] {
        guard let stored, !stored.isEmpty else { return [] }
        return stored.split(separator: ",").compactMap { LiftMuscle(rawValue: String($0)) }
    }
}
