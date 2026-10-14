import Foundation

// MARK: - Stress copy (zoop.stress.* catalogue entries)
//
// Every sentence is keyed so the German and English entries sit together. Meanings are one sentence per
// band, never free text, and the screen states only what the data supports.

enum StressStrings {
    // Labels
    static let label = LocalizedStringResource("zoop.stress.label", defaultValue: "Stress")
    static func now(_ time: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.stress.label.now", defaultValue: "Now · \(time)")
    }
    static func at(_ time: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.stress.label.at", defaultValue: "At \(time)")
    }
    static let thisMorning = LocalizedStringResource("zoop.stress.label.morning", defaultValue: "This morning")

    // Meanings, one per band
    static let meaningLow = LocalizedStringResource("zoop.stress.meaning.low",
        defaultValue: "Calm: your heart rate and HRV are at or better than your usual level.")
    static let meaningMedium = LocalizedStringResource("zoop.stress.meaning.medium",
        defaultValue: "A normal amount of activation for a day on your feet.")
    static let meaningHigh = LocalizedStringResource("zoop.stress.meaning.high",
        defaultValue: "Your body is more activated than usual. Slow breathing can bring it down.")
    static let meaningNone = LocalizedStringResource("zoop.stress.meaning.none",
        defaultValue: "Wear your strap through the day and the curve fills in.")

    // Cards
    static let curveEmpty = LocalizedStringResource("zoop.stress.curve.empty",
        defaultValue: "The curve fills in as the strap records your heart rate through the day.")
    static let sleepShade = LocalizedStringResource("zoop.stress.curve.sleep", defaultValue: "Shaded: sleep")
    static let todayCard = LocalizedStringResource("zoop.stress.card.today", defaultValue: "Today")
    static let highest = LocalizedStringResource("zoop.stress.today.highest", defaultValue: "Highest")
    static let lowest = LocalizedStringResource("zoop.stress.today.lowest", defaultValue: "Lowest")
    static let average = LocalizedStringResource("zoop.stress.today.average", defaultValue: "Average")
    static let timeHigh = LocalizedStringResource("zoop.stress.today.timeHigh", defaultValue: "Time in high")
    static func levelAt(_ level: String, _ time: String) -> String {
        String(localized: "zoop.stress.today.levelAt", defaultValue: "\(level) at \(time)")
    }
    static let trendCard = LocalizedStringResource("zoop.stress.card.trend", defaultValue: "Trend")
    static let week = LocalizedStringResource("zoop.stress.trend.week", defaultValue: "7 days")
    static let month = LocalizedStringResource("zoop.stress.trend.month", defaultValue: "30 days")
    static let trendEmpty = LocalizedStringResource("zoop.stress.trend.empty",
        defaultValue: "Needs a few more days of sleep data before a trend shows.")
    static let typicalBand = LocalizedStringResource("zoop.stress.trend.typical", defaultValue: "Your typical range")
    static let curveSummary = LocalizedStringResource("zoop.stress.curve.a11y", defaultValue: "Stress through today")
    static let trendSummary = LocalizedStringResource("zoop.stress.trend.a11y", defaultValue: "Daily stress trend")

    // Breathing
    static let breatheCard = LocalizedStringResource("zoop.stress.card.breathe", defaultValue: "Breathe")
    static let breatheHigh = LocalizedStringResource("zoop.stress.breathe.high",
        defaultValue: "Your stress has been high. Two minutes of slow breathing can bring it down.")
    static let breatheCalm = LocalizedStringResource("zoop.stress.breathe.calm",
        defaultValue: "Two minutes of slow breathing, whenever you want it.")
    static let breatheStart = LocalizedStringResource("zoop.stress.breathe.start", defaultValue: "Start breathing")
    static let breatheDone = LocalizedStringResource("zoop.stress.breathe.done", defaultValue: "Done")

    // Label the user gives after a breathing session (stored on this device only)
    static let askTitle = LocalizedStringResource("zoop.stress.ask.title", defaultValue: "Were you stressed?")
    static let askBody = LocalizedStringResource("zoop.stress.ask.body",
        defaultValue: "Your answer stays on this device and tunes when Zoop suggests breathing.")
    static let askYes = LocalizedStringResource("zoop.stress.ask.yes", defaultValue: "Yes")
    static let askNo = LocalizedStringResource("zoop.stress.ask.no", defaultValue: "No")

    // Explainer
    static let whatItIs = LocalizedStringResource("zoop.stress.explain.what",
        defaultValue: "How activated your body is, from 0 (calm) to 3 (high). It is a hint from your heart, not a measurement of how you feel.")
    static let methodName = LocalizedStringResource("zoop.stress.explain.method", defaultValue: "Heart rate and HRV against your baseline")
    static let methodSummary = LocalizedStringResource("zoop.stress.explain.method.summary",
        defaultValue: "Each hour you are not exercising is compared with your own baseline. A higher heart rate and a lower HRV raise the score. Posture, caffeine and alcohol also move HRV.")
    static let methodSummaryHROnly = LocalizedStringResource("zoop.stress.explain.method.hronly",
        defaultValue: "Each hour you are not exercising is compared with your own baseline. A higher heart rate raises the score. Wrist HRV is too noisy by day to count yet.")
    static let confidenceReason = LocalizedStringResource("zoop.stress.explain.confidence",
        defaultValue: "Hourly stress is validated against one person only, so treat it as a hint.")
    static let calibratingReason = LocalizedStringResource("zoop.stress.explain.calibrating",
        defaultValue: "Your typical range needs about a week of days. Until then 1 to 2 stands in for it.")
    static let restingHR = LocalizedStringResource("zoop.stress.contributor.rhr", defaultValue: "Resting heart rate")
    static let hrv = LocalizedStringResource("zoop.stress.contributor.hrv", defaultValue: "HRV")
    static let higherThanUsual = LocalizedStringResource("zoop.stress.contributor.higher", defaultValue: "Higher than your usual")
    static let lowerThanUsual = LocalizedStringResource("zoop.stress.contributor.lower", defaultValue: "Lower than your usual")
    static let nearUsual = LocalizedStringResource("zoop.stress.contributor.near", defaultValue: "Near your usual")
    static let dataSource = "Strap heart rate"

    // Loading and empty
    static let loading = LocalizedStringResource("zoop.stress.loading", defaultValue: "Reading your heart rate…")
    static let noHistory = LocalizedStringResource("zoop.stress.empty",
        defaultValue: "No stress history yet. Wear your strap or import your WHOOP export in Data Sources.")

    // Test Centre only
    static let advancedCard = LocalizedStringResource("zoop.stress.advanced.title", defaultValue: "Advanced HRV (Test Centre)")
}
