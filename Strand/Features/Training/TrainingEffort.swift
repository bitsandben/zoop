import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Effort on one scale
//
// Effort is stored on Zoop's 0–100 axis. The user picks how it is shown (0–100 or WHOOP's 0–21), and
// every Training surface (week bars, load chart, gauges, session rows, workout detail) goes through
// this one type, so two cards can never print the same effort on different scales.

enum TrainingEffort {

    /// The stored 0–100 value on the user's scale.
    static func value(_ stored: Double, scale: EffortScale) -> Double {
        UnitFormatter.effortValue(stored, scale: scale)
    }

    /// The top of the user's scale: 100 or 21.
    static func scaleMax(_ scale: EffortScale) -> Double {
        value(100, scale: scale)
    }

    /// One decimal, in the app locale (the shared `UnitFormatter` helper prints a dot in German).
    static func text(_ stored: Double, scale: EffortScale) -> String {
        ZoopNumber.decimal(value(stored, scale: scale), digits: 1)
    }

    /// The session-row cell: the effort, or an en dash when the session captured none. A real 0 is data.
    static func cellLabel(strain: Double?, scale: EffortScale) -> String {
        guard let strain else { return "\u{2013}" }
        return text(strain, scale: scale)
    }

    // MARK: Load vocabulary

    /// WHOOP's published Day Strain categories are Light 0–9, Moderate 10–13, High 14–17 and All Out 18–21.
    /// Expressed on the stored 0–100 axis (x100/21) so the verdict does not move with the display scale.
    private static let moderateFrom = 10.0 / 21 * 100
    private static let highFrom = 14.0 / 21 * 100
    private static let allOutFrom = 18.0 / 21 * 100

    /// Verdict word for one session's effort.
    static func band(forStored stored: Double) -> LoadBand {
        if stored >= allOutFrom { return .overreaching }
        if stored >= highFrom { return .demanding }
        if stored >= moderateFrom { return .building }
        return .restorative
    }

    /// Verdict word for the week's load against the user's own norm, from the same gauge reading the
    /// gauge itself draws, so the card and the gauge cannot disagree. Nil while calibrating.
    static func band(for state: TrainingLoadGauge.State) -> LoadBand? {
        switch state {
        case .calibrating: return nil
        case .low: return .restorative
        case .optimal: return .building
        case .high: return .demanding
        }
    }
}
