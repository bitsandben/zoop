import Foundation
import WhoopStore

// Display names for the stored `LiftMuscle` vocabulary.
//
// `WhoopStore` holds no UI strings and the raw values are a stored-data contract, so names live
// here where they can be localized. Renaming a label is free; renaming a token is not. Names are
// the ones lifters use ("Lats"), recognisable in a gym in a few seconds.

extension LiftMuscle {
    /// Localized display name, e.g. "Front delts". A `String` (not `LocalizedStringKey`) because
    /// callers interpolate it, and an interpolated key would miss its lookup.
    var displayName: String {
        switch self {
        // Push
        case .chest:       return String(localized: "Chest")
        case .frontDelts:  return String(localized: "Front delts")
        case .sideDelts:   return String(localized: "Side delts")
        case .rearDelts:   return String(localized: "Rear delts")
        case .triceps:     return String(localized: "Triceps")
        // Pull
        case .lats:        return String(localized: "Lats")
        case .upperBack:   return String(localized: "Upper back")
        case .traps:       return String(localized: "Traps")
        case .biceps:      return String(localized: "Biceps")
        case .forearms:    return String(localized: "Forearms")
        // Legs
        case .quads:       return String(localized: "Quads")
        case .hamstrings:  return String(localized: "Hamstrings")
        case .glutes:      return String(localized: "Glutes")
        case .adductors:   return String(localized: "Adductors")
        case .abductors:   return String(localized: "Abductors")
        case .calves:      return String(localized: "Calves")
        // Trunk
        case .abs:         return String(localized: "Abs")
        case .obliques:    return String(localized: "Obliques")
        case .lowerBack:   return String(localized: "Lower back")
        case .neck:        return String(localized: "Neck")
        }
    }
}

extension LiftMuscle.Region {
    /// Localized section title for the muscle picker. "Push muscles", not "Push": the bare `"Push"`
    /// catalog key is Today's readiness nudge and translates to unrelated words in some locales.
    var displayName: String {
        switch self {
        case .push:  return String(localized: "Push muscles")
        case .pull:  return String(localized: "Pull muscles")
        case .legs:  return String(localized: "Leg muscles")
        case .trunk: return String(localized: "Trunk muscles")
        }
    }
}

// MARK: - Summarising a classification

enum LiftMuscleSummary {

    /// One line describing an exercise's classification, e.g. "Chest · Front delts, Triceps", or
    /// "Not classified" when it has no primary. The primary is listed first because the direct/indirect
    /// split is what the per-muscle rollup rests on.
    static func line(primary: LiftMuscle?, secondaries: [LiftMuscle]) -> String {
        guard let primary else { return String(localized: "Not classified") }
        let secondary = secondaries.filter { $0 != primary }
        guard !secondary.isEmpty else { return primary.displayName }
        let joined = secondary.map(\.displayName).joined(separator: ", ")
        return "\(primary.displayName) · \(joined)"
    }
}
