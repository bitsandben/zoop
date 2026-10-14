import Foundation

// MARK: - Sleep copy (zoop.sleep.* catalogue entries)
//
// Every new Sleep string, keyed so the German and English catalogue entries sit together. Meanings
// are one sentence per (metric, verdict) pair, never free text.

enum SleepStrings {
    // Labels
    static let score = LocalizedStringResource("zoop.sleep.label.score", defaultValue: "Sleep score")
    static let duration = LocalizedStringResource("zoop.sleep.label.duration", defaultValue: "Time asleep")
    static let efficiency = LocalizedStringResource("zoop.sleep.label.efficiency", defaultValue: "Efficiency")
    static let deep = LocalizedStringResource("zoop.sleep.label.deep", defaultValue: "Deep")
    static let rem = LocalizedStringResource("zoop.sleep.label.rem", defaultValue: "REM")
    static let light = LocalizedStringResource("zoop.sleep.label.light", defaultValue: "Light")
    static let awake = LocalizedStringResource("zoop.sleep.label.awake", defaultValue: "Awake")
    static let debt = LocalizedStringResource("zoop.sleep.label.debt", defaultValue: "Sleep debt")
    static let regularity = LocalizedStringResource("zoop.sleep.label.regularity", defaultValue: "Regularity")
    static let hrv = LocalizedStringResource("zoop.sleep.label.hrv", defaultValue: "HRV")
    static let restingHR = LocalizedStringResource("zoop.sleep.label.rhr", defaultValue: "Resting heart rate")
    static let respiratory = LocalizedStringResource("zoop.sleep.label.resp", defaultValue: "Breathing rate")
    static let spo2 = LocalizedStringResource("zoop.sleep.label.spo2", defaultValue: "Blood oxygen")
    static let skinTemp = LocalizedStringResource("zoop.sleep.label.skin", defaultValue: "Skin temperature")

    // Cards
    static let timelineCard = LocalizedStringResource("zoop.sleep.card.timeline", defaultValue: "Night timeline")
    static let stagesCard = LocalizedStringResource("zoop.sleep.card.stages", defaultValue: "Stages")
    static let rhythmCard = LocalizedStringResource("zoop.sleep.card.rhythm", defaultValue: "Debt and rhythm")
    static let vitalsCard = LocalizedStringResource("zoop.sleep.card.vitals", defaultValue: "Night vitals")
    static let napsCard = LocalizedStringResource("zoop.sleep.card.naps", defaultValue: "Naps")
    static let current = LocalizedStringResource("zoop.sleep.card.current", defaultValue: "As of today")

    // Night navigation
    static let lastNight = LocalizedStringResource("zoop.sleep.nav.lastNight", defaultValue: "Last night")
    static func nightsAgo(_ n: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.sleep.nav.nightsAgo", defaultValue: "\(n) nights ago")
    }
    static let previousNight = LocalizedStringResource("zoop.sleep.nav.previous", defaultValue: "Previous night")
    static let nextNight = LocalizedStringResource("zoop.sleep.nav.next", defaultValue: "Next night")
    static let noEarlierNight = LocalizedStringResource("zoop.sleep.nav.noEarlier",
                                                        defaultValue: "No earlier night stored yet.")
    static let editTimes = LocalizedStringResource("zoop.sleep.edit", defaultValue: "Edit sleep times")
    static let editedTimes = LocalizedStringResource("zoop.sleep.edited", defaultValue: "Edit sleep times (edited)")
    static let whyThisSleep = LocalizedStringResource("zoop.sleep.why", defaultValue: "Why this sleep?")
    static let whyHint = LocalizedStringResource("zoop.sleep.why.hint",
                                                 defaultValue: "Shows the heart rate and movement behind this night's start and end")

    // Timeline
    static let heartRate = LocalizedStringResource("zoop.sleep.timeline.hr", defaultValue: "Heart rate")
    static let movement = LocalizedStringResource("zoop.sleep.timeline.movement", defaultValue: "Movement")
    static let noStages = LocalizedStringResource("zoop.sleep.timeline.noStages",
                                                  defaultValue: "No stage data was recorded for this night.")
    static let estimatedStages = LocalizedStringResource("zoop.sleep.timeline.estimated",
                                                         defaultValue: "Stages are estimated from heart rate and movement.")
    static let ringStages = LocalizedStringResource("zoop.sleep.timeline.ring",
                                                    defaultValue: "Stages are the ring's raw classification, so expect more awake time than in the Oura app.")
    static let importedStages = LocalizedStringResource("zoop.sleep.timeline.imported",
                                                        defaultValue: "Imported totals; the timeline is drawn from them.")
    static func timelineSummary(_ asleep: String, _ inBed: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.sleep.timeline.a11y", defaultValue: "Hypnogram: \(asleep) asleep of \(inBed) in bed")
    }

    // Caveats
    static let lowConfidenceTitle = LocalizedStringResource("zoop.sleep.caveat.lowConfidence.title", defaultValue: "Low confidence")
    static let lowConfidenceText = LocalizedStringResource("zoop.sleep.caveat.lowConfidence.text",
                                                           defaultValue: "Lots of sleep but almost no deep or REM, which is more likely an estimate miss.")
    static let incompleteTitle = LocalizedStringResource("zoop.sleep.caveat.incomplete.title", defaultValue: "May be incomplete")
    static let incompleteText = LocalizedStringResource("zoop.sleep.caveat.incomplete.text",
                                                        defaultValue: "Little movement was recorded overnight, so the total may read short.")
    static let partialTitle = LocalizedStringResource("zoop.sleep.caveat.partial.title", defaultValue: "Partly recorded")
    static func partialText(_ percent: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.sleep.caveat.partial.text", defaultValue: "Stage data covers \(percent) % of this night.")
    }

    // Naps
    static let addNap = LocalizedStringResource("zoop.sleep.nap.add", defaultValue: "Add a nap")
    static let editNap = LocalizedStringResource("zoop.sleep.nap.edit", defaultValue: "Edit nap times")

    // Debt
    static func debtNone(_ need: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.sleep.debt.none",
                                defaultValue: "No sleep debt: your last two weeks covered your need of \(need).")
    }
    static func debtSome(_ tonight: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.sleep.debt.some", defaultValue: "Aim for about \(tonight) tonight to start paying it back.")
    }
    static let debtChart = LocalizedStringResource("zoop.sleep.debt.chart", defaultValue: "Last 14 nights against your need")

    // Regularity
    static func regularityHigh(_ midpoint: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.sleep.regularity.high", defaultValue: "Steady sleep times; your midpoint averages \(midpoint).")
    }
    static func regularityMedium(_ midpoint: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.sleep.regularity.medium", defaultValue: "Your sleep times vary somewhat; midpoint around \(midpoint).")
    }
    static func regularityLow(_ midpoint: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.sleep.regularity.low", defaultValue: "Your sleep times vary a lot; midpoint around \(midpoint).")
    }
    static let regularityPending = LocalizedStringResource("zoop.sleep.regularity.pending",
                                                           defaultValue: "Regularity needs about a week of nights worn.")

    // Shared
    static let noValueTonight = LocalizedStringResource("zoop.sleep.meaning.unavailable",
                                                        defaultValue: "Wear the strap overnight to see this value.")
    static let personalRangeReason = LocalizedStringResource(
        "zoop.sleep.range.reason",
        defaultValue: "Your range is your weighted average of recent nights ± one standard deviation (14-night half-life).")
    static let populationRangeReason = LocalizedStringResource(
        "zoop.sleep.range.population",
        defaultValue: "Until four nights are recorded, the range shown is a typical adult range.")
    static let importedScoreReason = LocalizedStringResource("zoop.sleep.score.imported",
                                                             defaultValue: "This night's score comes from your WHOOP import.")
}
