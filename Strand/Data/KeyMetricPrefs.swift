import Foundation
import SwiftUI

// MARK: - Editable Key-Metrics layout
//
// Display-only: the user picks which Today tiles show and in what order (default is the original
// order). Stored as a comma-joined string of metric keys in @AppStorage. Unknown keys are dropped
// on read; any known key missing from the saved list is appended (disabled) so new tiles aren't lost.

/// One of the Today screen's Key-Metric tiles. The rawValue is the stable persisted identifier.
enum KeyMetric: String, CaseIterable, Identifiable {
    case charge
    case effort
    case rest
    case hrv
    case restingHr
    case bloodOxygen
    case respiratory
    case steps
    case weight
    case calories
    /// Not in `defaultOrder`, so existing layouts are unchanged; opt-in via the layout editor.
    case skinTemp

    var id: String { rawValue }

    /// The tile's display label, matching the `StatTile(label:)` text on the grid.
    var title: String {
        switch self {
        case .charge:      return String(localized: "Charge")
        case .effort:      return String(localized: "Effort")
        case .rest:        return String(localized: "Rest")
        case .hrv:         return "HRV"
        case .restingHr:   return String(localized: "Resting HR")
        case .bloodOxygen: return String(localized: "Blood Oxygen")
        case .respiratory: return String(localized: "Respiratory")
        case .steps:       return String(localized: "Steps")
        case .weight:      return String(localized: "Weight")
        case .calories:    return String(localized: "Calories")
        // Same short label as `DashboardCard.skinTemp`, reusing its translation key.
        case .skinTemp:    return String(localized: "Skin Temp")
        }
    }

    /// The original grid order, used when the user hasn't customised the layout.
    static let defaultOrder: [KeyMetric] = [
        .charge, .effort, .rest, .hrv, .restingHr,
        .bloodOxygen, .respiratory, .steps, .weight, .calories,
    ]

    /// The tiles the dashboard offers. iOS keeps only what Home shows nowhere else (rings carry
    /// Recovery, Effort and Sleep; the Health monitor tile carries overnight vitals).
    static var offered: [KeyMetric] {
        #if os(iOS)
        [.steps, .calories, .weight]
        #else
        defaultOrder
        #endif
    }
}

/// Display-only persistence for the Key-Metrics layout: an ordered list of enabled tiles; absent
/// tiles are hidden.
enum KeyMetricPrefs {
    /// UserDefaults key: comma-joined `KeyMetric` rawValues in display order.
    static let layoutKey = "today.keyMetrics"

    /// Encodes an ordered list of enabled tiles into the stored string.
    static func encode(_ metrics: [KeyMetric]) -> String {
        metrics.map(\.rawValue).joined(separator: ",")
    }

    /// Decodes the stored string into the enabled tiles in saved order. Empty/unset yields the full
    /// default order; unknown tokens are ignored.
    static func decodeEnabled(_ raw: String) -> [KeyMetric] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return KeyMetric.defaultOrder }
        var seen = Set<KeyMetric>()
        var result: [KeyMetric] = []
        for token in trimmed.split(separator: ",") {
            // Trim each token: `KeyMetric(rawValue:)` matches exactly, so "charge, effort" would drop `effort`.
            let raw = token.trimmingCharacters(in: .whitespaces)
            if let m = KeyMetric(rawValue: raw), seen.insert(m).inserted {
                result.append(m)
            }
        }
        return result
    }
}
