import SwiftUI
import StrandAnalytics
import StrandDesign

/// The shared explanation for an activity-masked gap on the Stress screen and hosted Today cards.
/// Whole-phrase singular/plural variants keep the sentence natural in every catalog locale.
func stressActivityMaskedHoursCaption(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    return count == 1
        ? String(localized: "1 hour excluded — you were moving.")
        : String(localized: "\(count) hours excluded — you were moving.")
}

// MARK: - Stress band

enum StressBand {
    case low, medium, high

    /// The band boundaries belong to `DaytimeStress`, so every stress surface bands a level the same way.
    init(score: Double) {
        switch DaytimeStress.Band(level: score) {
        case .low:    self = .low
        case .medium: self = .medium
        case .high:   self = .high
        }
    }

    var title: String {
        switch self {
        case .low:    return String(localized: "LOW")
        case .medium: return String(localized: "MEDIUM")
        case .high:   return String(localized: "HIGH")
        }
    }

    var tone: StrandTone {
        switch self {
        case .low:    return .positive
        case .medium: return .warning
        case .high:   return .critical
        }
    }
}

// MARK: - Stress ramp (the WHOOP Stress sweep: blue → green → amber)
//
// The Stress screen's one ramp. WHOOP has NO gold: calm reads as the link blue, a
// balanced day as positive green, and a high-stress day as warning amber. The
// semicircle gauge fill, the day autonomic-load line, the Calm/Moderate/High totals bar
// and the trend all sample this SAME ramp, so the colour language is identical across
// the screen. Never the gold or red→green recovery ramp.

enum StressRamp {
    /// Band anchors, lifted from the shared palette (no hard-coded hex). These are the
    /// blue / green / amber the totals legend and band dots use, kept in lock-step with
    /// the gauge gradient below.
    static let calm    = StrandPalette.stressLow     // low — WHOOP blue
    static let steady  = StrandPalette.stressMedium  // medium — WHOOP green
    static let tense   = StrandPalette.stressHigh    // high — WHOOP orange

    /// The 3-stop gauge ramp, evenly spaced (blue → green → amber).
    static let stops: [Gradient.Stop] = [
        .init(color: calm,   location: 0.00),
        .init(color: steady, location: 0.50),
        .init(color: tense,  location: 1.00),
    ]

    /// The blue→green→amber gauge gradient, built from the WHOOP band anchors above.
    static let gradient = Gradient(stops: stops)

    /// Sample the ramp at a 0–3 stress score.
    static func color(_ score: Double) -> Color {
        StrandPalette.sample(stops: stops, at: min(max(score / 3.0, 0), 1))
    }
}
