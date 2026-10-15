#if os(iOS)
import SwiftUI

// MARK: - Insights copy (zoop.body.* catalogue entries)
//
// Generated alongside the German and English catalogue entries; edit both together.

enum BodyStrings {
    static let showsTitle = LocalizedStringResource("zoop.body.shows.title", defaultValue: "What your body shows")
    static let showsEmpty = LocalizedStringResource("zoop.body.shows.empty", defaultValue: "Nothing stands out yet. Keep wearing the strap and readings appear here.")
    static let vitalsTitle = LocalizedStringResource("zoop.body.vitals.title", defaultValue: "Vitals")
    static let vitalsNote = LocalizedStringResource("zoop.body.vitals.note", defaultValue: "Last night against your usual range, with the last 30 days.")
    static let vitalsAllTypical = LocalizedStringResource("zoop.body.vitals.allTypical", defaultValue: "All your vitals are in your usual range.")
    static func vitalsOneOutside(_ label: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.vitals.oneOutside", defaultValue: "\(label) is outside your usual range; the other vitals are typical.")
    }
    static func vitalsSeveralOutside(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.vitals.severalOutside", defaultValue: "\(count) vitals are outside your range; training, alcohol, heat or an infection can do this.")
    }
    static let vitalNotRecent = LocalizedStringResource("zoop.body.vitals.notRecent", defaultValue: "No recent night; wear the strap to sleep to update it.")
    static let vitalNeverMeasured = LocalizedStringResource("zoop.body.vitals.never", defaultValue: "Not measured yet by your strap or imports.")
    static let trendsTitle = LocalizedStringResource("zoop.body.trends.title", defaultValue: "Trends")
    static let trendMetricPicker = LocalizedStringResource("zoop.body.trends.metric", defaultValue: "Metric")
    static let trendWindowPicker = LocalizedStringResource("zoop.body.trends.window", defaultValue: "Period")
    static let trendRecovery = LocalizedStringResource("zoop.body.trends.recovery", defaultValue: "Recovery")
    static let trendStrain = LocalizedStringResource("zoop.body.trends.strain", defaultValue: "Strain")
    static let windowYear = LocalizedStringResource("zoop.body.trends.windowYear", defaultValue: "1 year")
    static func windowDays(_ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.trends.windowDays", defaultValue: "\(days) days")
    }
    static func trendTooFew(_ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.trends.tooFew", defaultValue: "Too few values in the last \(days) days to show a trend.")
    }
    static func trendNoClearChange(_ average: String, _ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.trends.noClearChange", defaultValue: "Average \(average), no clear change from the \(days) days before.")
    }
    static func trendHigher(_ average: String, _ change: String, _ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.trends.higher", defaultValue: "Average \(average), \(change) higher than the \(days) days before.")
    }
    static func trendLower(_ average: String, _ change: String, _ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.trends.lower", defaultValue: "Average \(average), \(change) lower than the \(days) days before.")
    }
    static func trendAverageOnly(_ average: String, _ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.trends.averageOnly", defaultValue: "Average \(average) over the last \(days) days.")
    }
    static func trendInRange(_ inside: Int, _ total: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.trends.inRange", defaultValue: "Band: your usual range. Dashed: this period's average. \(inside) of \(total) days in range.")
    }
    static let trendBandPending = LocalizedStringResource("zoop.body.trends.bandPending", defaultValue: "Your usual range appears after four days with a value. Dashed: this period's average.")
    static let patternsTitle = LocalizedStringResource("zoop.body.patterns.title", defaultValue: "Patterns")
    static let patternsNote = LocalizedStringResource("zoop.body.patterns.note", defaultValue: "Associations in your own days, not causes.")
    static let outcomePicker = LocalizedStringResource("zoop.body.patterns.outcome", defaultValue: "Measured on")
    static let habitsEmptyForOutcome = LocalizedStringResource("zoop.body.patterns.habits.empty", defaultValue: "Not enough days with and without a habit for this metric yet.")
    static let needsMoreData = LocalizedStringResource("zoop.body.patterns.pending.title", defaultValue: "Needs more data")
    static let pendingHabits = LocalizedStringResource("zoop.body.patterns.pending.habits", defaultValue: "Habits: answer the logbook for a few weeks, with yes and no days.")
    static let pendingWeekday = LocalizedStringResource("zoop.body.patterns.pending.weekday", defaultValue: "Weekdays: eight weeks of recovery values.")
    static let pendingEvening = LocalizedStringResource("zoop.body.patterns.pending.evening", defaultValue: "Evening stress: two weeks of evenings with the strap on.")
    static let outcomeRecovery = LocalizedStringResource("zoop.body.outcome.recovery", defaultValue: "Recovery")
    static let outcomeHRV = LocalizedStringResource("zoop.body.outcome.hrv", defaultValue: "HRV")
    static let outcomeSleep = LocalizedStringResource("zoop.body.outcome.sleep", defaultValue: "Sleep")
    static let outcomeRestingHR = LocalizedStringResource("zoop.body.outcome.rhr", defaultValue: "Resting HR")
    static let possessiveRecovery = LocalizedStringResource("zoop.body.possessive.recovery", defaultValue: "your recovery")
    static let possessiveHRV = LocalizedStringResource("zoop.body.possessive.hrv", defaultValue: "your HRV")
    static let possessiveSleep = LocalizedStringResource("zoop.body.possessive.sleep", defaultValue: "your sleep score")
    static let possessiveRestingHR = LocalizedStringResource("zoop.body.possessive.rhr", defaultValue: "your resting heart rate")
    static let with = LocalizedStringResource("zoop.body.patterns.with", defaultValue: "With")
    static let without = LocalizedStringResource("zoop.body.patterns.without", defaultValue: "Without")
    static func withVsWithout(_ timing: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.patterns.withVsWithout", defaultValue: "with vs. without, \(timing)")
    }
    static let sameDay = LocalizedStringResource("zoop.body.patterns.lag.sameDay", defaultValue: "same day")
    static let nextMorning = LocalizedStringResource("zoop.body.patterns.lag.nextMorning", defaultValue: "next morning")
    static func afterDays(_ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.patterns.lag.afterDays", defaultValue: "after \(days) days")
    }
    static func withWithoutDays(_ with: Int, _ without: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.patterns.sample", defaultValue: "\(with) days with, \(without) without")
    }
    static let linkAllMetrics = LocalizedStringResource("zoop.body.links.allMetrics", defaultValue: "All metrics")
    static let linkAllMetricsDetail = LocalizedStringResource("zoop.body.links.allMetrics.detail", defaultValue: "Search every metric and range")
    static let linkLabBook = LocalizedStringResource("zoop.body.links.labBook", defaultValue: "Lab book")
    static let linkLabBookDetail = LocalizedStringResource("zoop.body.links.labBook.detail", defaultValue: "Blood values, blood pressure, body measures")
    static let linkReport = LocalizedStringResource("zoop.body.links.report", defaultValue: "Trends report")
    static let linkReportDetail = LocalizedStringResource("zoop.body.links.report.detail", defaultValue: "Export a one-page PDF")
    static let sheetWhatItIs = LocalizedStringResource("zoop.body.sheet.whatItIs", defaultValue: "What it is")
    static let sheetMethod = LocalizedStringResource("zoop.body.sheet.method", defaultValue: "How it is computed")
    static let sheetDataUsed = LocalizedStringResource("zoop.body.sheet.dataUsed", defaultValue: "Data used")
    static let sheetConfidence = LocalizedStringResource("zoop.body.sheet.confidence", defaultValue: "Confidence")
    static let confidenceSolid = LocalizedStringResource("zoop.body.sheet.confidence.solid", defaultValue: "Solid")
    static let confidenceBuilding = LocalizedStringResource("zoop.body.sheet.confidence.building", defaultValue: "Still building")
    static let done = LocalizedStringResource("zoop.body.sheet.done", defaultValue: "Done")
    static let opensExplainer = LocalizedStringResource("zoop.body.a11y.opensExplainer", defaultValue: "Opens the explanation")
    static func sampleReason(_ count: Int, _ solid: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.sample.reason", defaultValue: "Based on \(count); from \(solid) on it counts as solid.")
    }
    static func days(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.sample.days", defaultValue: "\(count) days")
    }
    static func weeks(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.sample.weeks", defaultValue: "\(count) weeks")
    }
    static func workouts(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.sample.workouts", defaultValue: "\(count) workouts")
    }
    static func evenings(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.sample.evenings", defaultValue: "\(count) evenings")
    }
    static func hardDays(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.sample.hardDays", defaultValue: "\(count) hard days")
    }
    static func readingsIn30Days(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.sample.readings30", defaultValue: "\(count) readings in 30 days")
    }
    static let verdictStrong = LocalizedStringResource("zoop.body.verdict.strong", defaultValue: "Strong")
    static let verdictNoticeable = LocalizedStringResource("zoop.body.verdict.noticeable", defaultValue: "Noticeable")
    static let verdictLittle = LocalizedStringResource("zoop.body.verdict.little", defaultValue: "Little")
    static let verdictQuick = LocalizedStringResource("zoop.body.verdict.quick", defaultValue: "Quick")
    static let verdictSlow = LocalizedStringResource("zoop.body.verdict.slow", defaultValue: "Slow")
    static let verdictMostlyEasy = LocalizedStringResource("zoop.body.verdict.mostlyEasy", defaultValue: "Mostly easy")
    static let verdictMixed = LocalizedStringResource("zoop.body.verdict.mixed", defaultValue: "Mixed")
    static let verdictMostlyHard = LocalizedStringResource("zoop.body.verdict.mostlyHard", defaultValue: "Mostly hard")
    static let verdictClearPattern = LocalizedStringResource("zoop.body.verdict.clearPattern", defaultValue: "Clear pattern")
    static let verdictWeakPattern = LocalizedStringResource("zoop.body.verdict.weakPattern", defaultValue: "Weak pattern")
    static let verdictClearDifference = LocalizedStringResource("zoop.body.verdict.clearDifference", defaultValue: "Clear difference")
    static let verdictNoClearDifference = LocalizedStringResource("zoop.body.verdict.noClearDifference", defaultValue: "No clear difference")

    /// The habits card title, used as a `LocalizedStringKey` by `ContentCard`.
    static let habitsCardKey: LocalizedStringKey = "zoop.body.patterns.habits"

    static func outcomeLabel(_ o: BodyOutcome) -> LocalizedStringResource {
        switch o {
        case .recovery: return outcomeRecovery
        case .hrv: return outcomeHRV
        case .sleep: return outcomeSleep
        case .restingHR: return outcomeRestingHR
        }
    }

    /// The outcome with its possessive, for use inside a sentence ("your recovery").
    static func possessive(_ o: BodyOutcome) -> LocalizedStringResource {
        switch o {
        case .recovery: return possessiveRecovery
        case .hrv: return possessiveHRV
        case .sleep: return possessiveSleep
        case .restingHR: return possessiveRestingHR
        }
    }

    /// A name that is already localized (a habit) carried as a resource.
    static func verbatim(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(text))
    }
}
#endif
