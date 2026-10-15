import SwiftUI
import StrandDesign

extension StressBand {
    /// The band in sentence case, as the Stress hero states it.
    var name: String {
        switch self {
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high: return String(localized: "High")
        }
    }

    /// The Stress ramp colour of the band.
    var color: Color {
        switch self {
        case .low: return StrandPalette.stressLow
        case .medium: return StrandPalette.stressMedium
        case .high: return StrandPalette.stressHigh
        }
    }
}
