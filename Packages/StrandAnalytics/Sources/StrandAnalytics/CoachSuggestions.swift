import Foundation
import WhoopStore

// CoachSuggestions.swift - contextual coaching prompt chips derived from the user's own bands.
// Pure and deterministic; reads only on-device DailyMetric fields.

/// Contextual suggestion chips for the Coach composer, derived from today's bands.
public enum CoachSuggestions {

    public static let fallback: [String] = [
        "How's my recovery trending this week?",
        "What should today's training look like?",
        "Analyse my sleep",
        "Why am I run down?",
    ]

    private static let stableGeneric = "Analyse my sleep"

    /// Charge band cutoffs (mirror the autoregulation bands in `AICoachEngine.defaultSystemPrompt`).
    private static let chargeRedCutoff: Double = 34
    private static let chargeGreenCutoff: Double = 67
    /// HRV "trending down": today's HRV below 85% of the trailing-30-day baseline (excluding today).
    private static let hrvDownRatio: Double = 0.85
    /// "Poor night" cutoff: under 6h (360 min).
    private static let poorSleepMin: Double = 360
    /// "Already loaded" cutoff on the 0-21 Day Strain axis, compared through
    /// `StrainScorer.effortValue(fromWhoopStrain:)` because `DailyMetric.strain` is stored 0-100.
    private static let highStrain: Double = 14
    private static let maxChips: Int = 4

    /// Builds 2-4 contextual prompt chips from today's bands, or `fallback` when there is no usable data.
    /// `recent` is oldest to newest and feeds the trailing-30-day HRV baseline.
    public static func suggestions(for today: DailyMetric?, recent: [DailyMetric]) -> [String] {
        guard let today else { return fallback }
        let charge = today.recovery
        let hrv = today.avgHrv
        let sleep = today.totalSleepMin
        let strain = today.strain
        // No usable signal at all: generic fallback.
        guard charge != nil || hrv != nil || sleep != nil || strain != nil else { return fallback }

        var chips: [String] = []

        // 1. Charge band: one readiness chip.
        if let c = charge {
            if c < chargeRedCutoff {
                chips.append("Active recovery only today — what should I do?")
            } else if c < chargeGreenCutoff {
                chips.append("Quality over volume today — plan my session")
            } else {
                chips.append("Green light — how hard can I push today?")
            }
        }

        // 2. HRV trending down vs trailing-30-day baseline (excluding today).
        if let h = hrv {
            let baseline = hrvBaseline(recent, excluding: today.day)
            if let avg = baseline, avg > 0, h < hrvDownRatio * avg {
                chips.append("Why is my HRV trending down?")
            }
        }

        // 3. Poor sleep (< 6h).
        if let s = sleep, s < poorSleepMin {
            chips.append("I slept poorly — how do I recover today?")
        }

        // 4. High-strain day.
        if let st = strain, st >= StrainScorer.effortValue(fromWhoopStrain: highStrain) {
            chips.append("Have I done enough today, or push more?")
        }

        // Signals present but no band fired: fallback rather than a lone stable chip.
        guard !chips.isEmpty else { return fallback }
        // Cap contextual chips at maxChips - 1 so the stable chip always survives as the last one.
        return Array(chips.prefix(maxChips - 1)) + [stableGeneric]
    }

    /// Mean `avgHrv` over the trailing 30 days of `recent`, excluding `excludingDay`; nil when none qualify.
    private static func hrvBaseline(_ recent: [DailyMetric], excluding day: String) -> Double? {
        let values = recent.suffix(30).filter { $0.day != day }.compactMap { $0.avgHrv }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
