import SwiftUI
import StrandDesign

extension TodaySection {
    var customizationIcon: String {
        switch self {
        case .hero: return "gauge.with.dots.needle.67percent"
        case .liveSession: return "figure.run.circle"
        case .synthesis: return "sparkles"
        case .keyMetrics: return "square.grid.2x2"
        case .workouts: return "figure.run"
        case .heartRate: return "waveform.path.ecg"
        case .recoveryVitals: return "heart.text.square"
        case .yourCards: return "rectangle.stack"
        case .menstrualCycle: return "drop.degreesign"
        case .journal: return "book.closed"
        case .addedCards: return "rectangle.stack.badge.plus"
        }
    }

    var customizationTint: Color {
        switch self {
        case .hero: return StrandPalette.chargeColor
        case .liveSession: return StrandPalette.metricCyan
        case .synthesis: return StrandPalette.accent
        case .keyMetrics: return StrandPalette.metricPurple
        case .workouts: return StrandPalette.effortColor
        case .heartRate: return StrandPalette.metricRose
        case .recoveryVitals: return StrandPalette.metricCyan
        case .yourCards: return StrandPalette.accent
        case .menstrualCycle: return StrandPalette.restColor
        case .journal: return StrandPalette.metricAmber
        case .addedCards: return StrandPalette.accent
        }
    }
}

extension KeyMetric {
    var customizationIcon: String {
        switch self {
        case .charge: return "bolt.heart"
        case .effort: return "figure.run"
        case .rest: return "moon.stars"
        case .hrv: return "waveform.path.ecg"
        case .restingHr: return "heart.fill"
        case .bloodOxygen: return "drop.fill"
        case .respiratory: return "lungs.fill"
        case .steps: return "figure.walk"
        case .weight: return "scalemass"
        case .calories: return "flame.fill"
        // Same glyph the sibling "Your Cards" tile (`DashboardCard.skinTemp`) already uses.
        case .skinTemp: return "thermometer.medium"
        }
    }

    var customizationTint: Color {
        switch self {
        case .charge: return StrandPalette.chargeColor
        case .effort: return StrandPalette.effortColor
        case .rest, .hrv: return StrandPalette.metricPurple
        case .restingHr: return StrandPalette.metricRose
        case .bloodOxygen, .steps: return StrandPalette.metricCyan
        case .respiratory, .weight: return StrandPalette.accent
        case .calories, .skinTemp: return StrandPalette.metricAmber
        }
    }
}

extension DashboardCard {
    var customizationTint: Color {
        switch self {
        case .stress, .respiratory: return StrandPalette.accent
        case .fitnessAge: return StrandPalette.chargeColor
        case .vo2max: return StrandPalette.chargeColor
        case .vitality, .hrv: return StrandPalette.metricPurple
        case .restingHr: return StrandPalette.metricRose
        case .steps, .stepsAverage30, .bloodOxygen, .hydration: return StrandPalette.metricCyan
        case .skinTemp, .calories: return StrandPalette.metricAmber
        case .sleep: return StrandPalette.restColor
        case .coupled: return StrandPalette.chargeColor
        case .coach: return StrandPalette.accent
        }
    }
}

// MARK: - Categories
//
// Each customizable item belongs to one category, so the editor lists hidden items by category and
// labels shown ones with theirs instead of presenting one mixed list.

extension TodaySection {
    var customizationCategory: String {
        switch self {
        case .hero, .synthesis: return String(localized: "Scores")
        case .keyMetrics, .yourCards, .addedCards: return String(localized: "Dashboard")
        case .workouts, .heartRate, .liveSession: return String(localized: "Activity")
        case .recoveryVitals: return String(localized: "Vitals")
        case .menstrualCycle, .journal: return String(localized: "Tracking")
        }
    }
}

extension KeyMetric {
    var customizationCategory: String {
        switch self {
        case .charge, .effort, .rest: return String(localized: "Scores")
        case .hrv, .restingHr, .bloodOxygen, .respiratory, .skinTemp: return String(localized: "Vitals")
        case .steps, .calories: return String(localized: "Activity")
        case .weight: return String(localized: "Body")
        }
    }
}

extension DashboardCard {
    var customizationCategory: String {
        switch self {
        case .hrv, .restingHr, .respiratory, .bloodOxygen, .skinTemp: return String(localized: "Vitals")
        case .steps, .stepsAverage30, .calories, .hydration: return String(localized: "Activity")
        case .stress, .sleep: return String(localized: "Recovery & sleep")
        case .fitnessAge, .vo2max, .vitality: return String(localized: "Longevity")
        case .coupled, .coach: return String(localized: "Insights")
        }
    }
}
