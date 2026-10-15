import Foundation

// MARK: - Stress patterns copy (zoop.stress.patterns.* catalogue entries)
//
// One sentence per card. The time-of-day explainer reuses the Insights stress-timing entries, because
// it is the same reading.

enum StressPatternStrings {
    static let title = LocalizedStringResource("zoop.stress.patterns.title", defaultValue: "Patterns")

    // Through the day
    static let dayTitle = LocalizedStringResource("zoop.stress.patterns.day.title", defaultValue: "Through the day")
    static func dayPeak(_ peak: String, _ calm: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.stress.patterns.day.peak", defaultValue: "Usually highest around \(peak), calmest around \(calm).")
    }
    static let dayFlat = LocalizedStringResource("zoop.stress.patterns.day.flat",
        defaultValue: "No clear daily rhythm in your last 14 days.")
    static let dayPending = LocalizedStringResource("zoop.stress.patterns.day.pending",
        defaultValue: "Your typical day appears after a week of wearing the strap by day.")
    static let dayLoading = LocalizedStringResource("zoop.stress.patterns.day.loading", defaultValue: "Reading your last 14 days…")
    static let dayA11y = LocalizedStringResource("zoop.stress.patterns.day.a11y", defaultValue: "Typical stress by hour of day")
    static let dayWhat = LocalizedStringResource("zoop.body.stressTiming.what",
        defaultValue: "When in the day your stress level tends to rise and settle.")
    static let dayMethod = LocalizedStringResource("zoop.body.stressTiming.method", defaultValue: "Hourly average")
    static let dayMethodSummary = LocalizedStringResource("zoop.body.stressTiming.method.summary",
        defaultValue: "Hourly stress of your last 14 days between 07:00 and 23:00, averaged for each hour.")
    static let dayRelative = LocalizedStringResource("zoop.stress.patterns.day.relative",
        defaultValue: "Each day is scored against its own typical hour, so the curve shows your rhythm, not one day against another. Dashed: your day average.")
    static func dayData(_ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.stressTiming.data", defaultValue: "\(days) days with enough heart-rate data.")
    }

    // Workdays and weekend
    static let weekTitle = LocalizedStringResource("zoop.stress.patterns.week.title", defaultValue: "Workdays and weekend")
    static let workdays = LocalizedStringResource("zoop.stress.patterns.week.workdays", defaultValue: "Mon–Fri")
    static let weekend = LocalizedStringResource("zoop.stress.patterns.week.weekend", defaultValue: "Sat–Sun")
    static let weekCalmer = LocalizedStringResource("zoop.stress.patterns.week.calmer",
        defaultValue: "Your weekends are calmer than your workdays.")
    static let weekMoreStressed = LocalizedStringResource("zoop.stress.patterns.week.more",
        defaultValue: "Your weekends are more stressful than your workdays.")
    static let weekNoClear = LocalizedStringResource("zoop.stress.patterns.week.noClear",
        defaultValue: "No clear difference between workdays and weekend.")
    static let weekPending = LocalizedStringResource("zoop.stress.patterns.week.pending",
        defaultValue: "Needs about two weeks of daily stress levels.")
    static let weekA11y = LocalizedStringResource("zoop.stress.patterns.week.a11y", defaultValue: "Average stress per weekday")
    static func days(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.stress.patterns.days", defaultValue: "\(count) days")
    }
    static let weekWhat = LocalizedStringResource("zoop.stress.patterns.week.what",
        defaultValue: "Whether your stress differs between workdays and the weekend.")
    static let weekMethod = LocalizedStringResource("zoop.stress.patterns.week.method", defaultValue: "Welch's t-test")
    static let weekMethodSummary = LocalizedStringResource("zoop.stress.patterns.week.method.summary",
        defaultValue: "Daily stress of the last 8 weeks, Mon–Fri against Sat–Sun; clear means p < 0.05 and at least 0.25 apart.")
    static let weekSource = LocalizedStringResource("zoop.stress.patterns.week.source",
        defaultValue: "A day's level comes from the night before it (resting heart rate and HRV) or from imported WHOOP stress.")
    static func weekData(_ workdays: Int, _ weekend: Int, _ p: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.stress.patterns.week.data",
            defaultValue: "\(workdays) workdays and \(weekend) weekend days; p = \(p).")
    }

    // Explainer
    static let whatItIs = LocalizedStringResource("zoop.body.sheet.whatItIs", defaultValue: "What it is")
    static let method = LocalizedStringResource("zoop.body.sheet.method", defaultValue: "How it is computed")
    static let dataUsed = LocalizedStringResource("zoop.body.sheet.dataUsed", defaultValue: "Data used")
    static let explain = LocalizedStringResource("zoop.stress.patterns.explain", defaultValue: "Explanation")
}
