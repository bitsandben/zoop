import Foundation

// MARK: - Training copy (zoop.training.* catalogue entries)
//
// The keys live in the app catalogue (Strand/Resources/Localizable.xcstrings) and resolve against the
// running app, so tests and previews fall back to the English default value. Resolved to `String` at
// the point of use, like the rest of the app's `String(localized:)` copy, so the app-language override
// applies.

enum TrainingStrings {

    // Empty page
    static var emptyTitle: String { String(localized: "zoop.training.empty.title", defaultValue: "No training yet", bundle: .main) }
    static var emptyBody: String {
        String(localized: "zoop.training.empty.body",
               defaultValue: "Sessions arrive from your WHOOP or Apple Health, or you add one you tracked elsewhere.", bundle: .main)
    }

    // Week
    static var weekTitle: String { String(localized: "zoop.training.week.title", defaultValue: "Last 7 days", bundle: .main) }
    static var weekEmpty: String { String(localized: "zoop.training.week.empty", defaultValue: "No training in the last 7 days.", bundle: .main) }
    static var barsAccessibility: String {
        String(localized: "zoop.training.week.bars.a11y", defaultValue: "Effort per day, last 7 days", bundle: .main)
    }
    static func barsCaption(maxValue: String) -> String {
        String(localized: "zoop.training.week.bars.caption", defaultValue: "Effort per day, scale 0\u{2013}\(maxValue)", bundle: .main)
    }
    static func sessionCount(_ count: Int) -> String {
        String(localized: "zoop.training.sessions.count", defaultValue: "\(count) sessions", bundle: .main)
    }
    static var time: String { String(localized: "zoop.training.week.time", defaultValue: "Time", bundle: .main) }
    static var energy: String { String(localized: "zoop.training.week.energy", defaultValue: "Energy", bundle: .main) }
    static var distance: String { String(localized: "zoop.training.week.distance", defaultValue: "Distance", bundle: .main) }
    static var zones: String { String(localized: "zoop.training.week.zones", defaultValue: "Heart-rate zones", bundle: .main) }

    // Fitness and fatigue
    static var fitnessTitle: String { String(localized: "zoop.training.fitness.title", defaultValue: "Fitness & fatigue", bundle: .main) }
    static var fitness: String { String(localized: "zoop.training.fitness.fitness", defaultValue: "Fitness", bundle: .main) }
    static var fatigue: String { String(localized: "zoop.training.fitness.fatigue", defaultValue: "Fatigue", bundle: .main) }
    static var fitnessExplain: String {
        String(localized: "zoop.training.fitness.explain",
               defaultValue: "Fitness is your 42-day average Effort, fatigue the 7-day average. The gap between them is your form.",
               bundle: .main)
    }
    static var fitnessAccessibility: String {
        String(localized: "zoop.training.fitness.a11y", defaultValue: "Fitness and fatigue over the last six weeks", bundle: .main)
    }
    static func fitnessNeedsDays(minimum: Int, have: Int) -> String {
        String(localized: "zoop.training.fitness.needsDays",
               defaultValue: "Fitness and fatigue need \(minimum) days of Effort in a row. You have \(have) so far.", bundle: .main)
    }
    static var takeawayCalibrating: String {
        String(localized: "zoop.training.fitness.takeaway.calibrating",
               defaultValue: "Zoop needs about three weeks of history before it compares your week with your norm.", bundle: .main)
    }
    static var takeawayLow: String {
        String(localized: "zoop.training.fitness.takeaway.low",
               defaultValue: "Your last 7 days were lighter than your usual load.", bundle: .main)
    }
    static var takeawayOptimal: String {
        String(localized: "zoop.training.fitness.takeaway.optimal",
               defaultValue: "Your last 7 days match the load you are used to.", bundle: .main)
    }
    static var takeawayHigh: String {
        String(localized: "zoop.training.fitness.takeaway.high",
               defaultValue: "Your last 7 days were heavier than your usual load.", bundle: .main)
    }

    // Gauges, muscles, sessions
    static var gaugesTitle: String { String(localized: "zoop.training.gauges.title", defaultValue: "Weekly load", bundle: .main) }
    static var allMusclesRecovered: String {
        String(localized: "zoop.training.muscle.allRecovered", defaultValue: "All muscle groups are recovered.", bundle: .main)
    }
    static var sessionsTitle: String { String(localized: "zoop.training.sessions.title", defaultValue: "Sessions", bundle: .main) }
    static var nothingArchived: String {
        String(localized: "zoop.training.sessions.nothingArchived", defaultValue: "Nothing archived yet.", bundle: .main)
    }
    static var noMatches: String {
        String(localized: "zoop.training.sessions.noMatches", defaultValue: "No sessions match this filter.", bundle: .main)
    }

    // Workout detail
    static var zonesImported: String {
        String(localized: "zoop.training.detail.zones.imported",
               defaultValue: "The per-zone split imported for this session.", bundle: .main)
    }
    static var zonesDerived: String {
        String(localized: "zoop.training.detail.zones.derived",
               defaultValue: "Time in each heart-rate zone, derived from the strap's heart rate over this window (approximate).",
               bundle: .main)
    }

    // Spoken forms
    static func zoneSplitAccessibility(percents: [Int]) -> String {
        let zones = percents.enumerated().map { index, percent in
            String(localized: "zoop.training.zone.a11y", defaultValue: "zone \(index + 1) \(percent) percent", bundle: .main)
        }
        return String(localized: "zoop.training.zoneSplit.a11y",
                      defaultValue: "Heart-rate zone split: \(zones.joined(separator: ", "))", bundle: .main)
    }
}
