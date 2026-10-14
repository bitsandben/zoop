import Foundation

/// Shared "7h 12m" duration text. Strings stay localized through the existing `%lldm` and
/// `%lldh %lldm` catalog keys.
enum ZoopDuration {
    /// "7h 12m" from minutes; "52m" under an hour; negative values clamp to "0m".
    static func text(minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }
}
