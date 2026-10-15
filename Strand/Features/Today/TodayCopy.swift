import Foundation
import StrandDesign

// MARK: - Today copy (zoop.today.* catalogue entries)
//
// Every sentence on the Today screen, one per (metric, verdict). Kept in one place so a verdict reads the
// same wherever its readout appears, and so the catalogue keys are easy to audit.

enum TodayCopy {
    private static func r(_ key: StaticString, _ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: value)
    }

    // MARK: Labels

    static let recovery = r("zoop.today.label.recovery", "Recovery")
    static let sleep = r("zoop.today.label.sleep", "Sleep")
    static let strain = r("zoop.today.label.strain", "Strain")
    static let stress = r("zoop.today.label.stress", "Stress")
    static let health = r("zoop.today.label.health", "Health monitor")
    static let energy = r("zoop.today.label.energy", "Energy Bank")
    static let steps = r("zoop.today.label.steps", "Steps")
    static let calories = r("zoop.today.label.calories", "Active calories")
    static let weight = r("zoop.today.label.weight", "Weight")
    static let fitnessAge = r("zoop.today.label.fitnessAge", "Fitness age")
    static let myDay = r("zoop.today.section.myDay", "My Day")
    static let dashboard = r("zoop.today.section.dashboard", "My Dashboard")

    // MARK: Dashboard tiles and the customise sheet

    static let tileHRV = r("zoop.today.tile.hrv", "HRV")
    static let tileRestingHR = r("zoop.today.tile.restingHR", "Resting HR")
    static let tileRespiratory = r("zoop.today.tile.respiratory", "Respiratory rate")
    static let tileSpO2 = r("zoop.today.tile.spo2", "SpO₂")
    static let tileSkinTemp = r("zoop.today.tile.skinTemp", "Skin temperature")
    static let tileStressDaily = r("zoop.today.tile.stressDaily", "Stress (daily average)")
    static let tileSleepDebt = r("zoop.today.tile.sleepDebt", "Sleep debt")
    static let tileVO2max = r("zoop.today.tile.vo2max", "VO₂max")
    static let tileFasting = r("zoop.today.tile.fasting", "Fasting streak")
    static let customise = r("zoop.today.dashboard.customise", "Customise")
    static let customiseTitle = r("zoop.today.dashboard.customiseTitle", "My Dashboard")
    static let customiseShown = r("zoop.today.dashboard.shown", "On your dashboard")
    static let customiseShownNote = r("zoop.today.dashboard.shownNote", "Drag to reorder, swipe to remove.")
    static let customiseMore = r("zoop.today.dashboard.more", "More tiles")
    static let customiseReset = r("zoop.today.dashboard.reset", "Restore defaults")
    static let customiseDone = r("zoop.today.dashboard.done", "Done")
    static let dashboardEmpty = r("zoop.today.dashboard.empty", "Pick the numbers you want to see here.")
    static let stressDailyNoData = r("zoop.today.stressDaily.noData", "Your daily stress appears after a day with the strap.")
    static let fastingNoData = r("zoop.today.fasting.noData", "Finish a fast and your streak starts here.")
    static func fastingMeaning(met: Int, of days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.today.fasting.meaning", defaultValue: "You met your fasting goal on \(met) of the last \(days) days.")
    }
    static let vo2NoData = r("zoop.today.vo2max.noData", "Needs a week of resting heart rate plus your age and sex.")
    static let vitalNoData = r("zoop.today.vital.noData", "Not measured on this day.")

    // MARK: Meanings, one sentence per verdict

    static func recoveryMeaning(_ band: ScoreBand) -> LocalizedStringResource {
        switch band {
        case .high: return r("zoop.today.recovery.high", "Your body has recovered well, so a hard day fits.")
        case .medium: return r("zoop.today.recovery.medium", "You have partly recovered, so keep the load moderate.")
        case .low: return r("zoop.today.recovery.low", "Your body is still recovering, so go easy today.")
        }
    }
    static let recoveryCalibrating = r("zoop.today.recovery.calibrating", "Wear the strap tonight so Zoop can learn your baseline.")
    static let recoveryNoData = r("zoop.today.recovery.noData", "No scored night for this day.")

    static func sleepMeaning(_ band: ScoreBand) -> LocalizedStringResource {
        switch band {
        case .high: return r("zoop.today.sleep.high", "You slept well and covered most of your need.")
        case .medium: return r("zoop.today.sleep.medium", "Your sleep covered part of what you needed.")
        case .low: return r("zoop.today.sleep.low", "Short or restless sleep, so plan an early night.")
        }
    }
    static let sleepNoData = r("zoop.today.sleep.noData", "No sleep recorded for this night.")

    static func strainMeaning(_ band: LoadBand) -> LocalizedStringResource {
        switch band {
        case .restorative: return r("zoop.today.strain.restorative", "A light load so far, so your body can rebuild.")
        case .building: return r("zoop.today.strain.building", "A steady load that builds fitness.")
        case .demanding: return r("zoop.today.strain.demanding", "A hard day, so give recovery priority tonight.")
        case .overreaching: return r("zoop.today.strain.overreaching", "A very hard day, so plan an easy one tomorrow.")
        }
    }
    static let strainNoData = r("zoop.today.strain.noData", "No heart rate recorded for this day yet.")
    static func strainTarget(_ low: String, _ high: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.today.strain.target", defaultValue: "Target \(low)–\(high)")
    }

    static func vitalMeaning(_ id: VitalCopyID, _ word: RangeVerdict) -> LocalizedStringResource {
        switch (id, word) {
        case (.stress, .typical): return r("zoop.today.stress.typical", "Your stress sits in its usual range.")
        case (.stress, .above): return r("zoop.today.stress.above", "Your stress is higher than usual.")
        case (.stress, .below): return r("zoop.today.stress.below", "You are calmer than usual.")
        case (.steps, .typical): return r("zoop.today.steps.typical", "A usual amount of walking for you.")
        case (.steps, .above): return r("zoop.today.steps.above", "More steps than on most of your days.")
        case (.steps, .below): return r("zoop.today.steps.below", "Fewer steps than on most of your days so far.")
        case (.calories, .typical): return r("zoop.today.calories.typical", "Your active energy is in its usual range.")
        case (.calories, .above): return r("zoop.today.calories.above", "You burned more active energy than usual.")
        case (.calories, .below): return r("zoop.today.calories.below", "Less active energy than usual so far.")
        case (.weight, .typical): return r("zoop.today.weight.typical", "Your weight matches your recent weigh-ins.")
        case (.weight, .above): return r("zoop.today.weight.above", "Heavier than your recent weigh-ins.")
        case (.weight, .below): return r("zoop.today.weight.below", "Lighter than your recent weigh-ins.")
        case (.fitnessAge, .typical): return r("zoop.today.fitnessAge.typical", "Your fitness age matches your actual age.")
        case (.fitnessAge, .above): return r("zoop.today.fitnessAge.above", "Your fitness age is above your actual age.")
        case (.fitnessAge, .below): return r("zoop.today.fitnessAge.below", "Your fitness age is below your actual age.")
        }
    }
    static let stressNoData = r("zoop.today.stress.noData", "Stress builds up through the day from your heart rate.")
    static let stepsNoData = r("zoop.today.steps.noData", "No steps recorded for this day.")
    static let caloriesNoData = r("zoop.today.calories.noData", "No active energy recorded for this day.")
    static let weightNoData = r("zoop.today.weight.noData", "Log your weight in Apple Health to see it here.")
    static let fitnessAgeNoData = r("zoop.today.fitnessAge.noData", "Needs a week of resting heart rate plus your age and sex.")

    static func energyMeaning(_ band: ScoreBand) -> LocalizedStringResource {
        switch band {
        case .high: return r("zoop.today.energy.high", "Plenty of energy left for today.")
        case .medium: return r("zoop.today.energy.medium", "Your energy is holding, so pace yourself.")
        case .low: return r("zoop.today.energy.low", "Your energy is low, and rest will refill it.")
        }
    }
    static let energyNoData = r("zoop.today.energy.noData", "Wear the strap and your Energy Bank fills in.")

    // MARK: Synthesis (the one sentence under the rings)

    static func synthesis(_ band: ScoreBand) -> LocalizedStringResource {
        switch band {
        case .high: return r("zoop.today.synthesis.high", "Well recovered: today can take a hard session.")
        case .medium: return r("zoop.today.synthesis.medium", "Partly recovered: aim for a moderate day.")
        case .low: return r("zoop.today.synthesis.low", "Still recovering: keep today light and sleep early.")
        }
    }
    static let synthesisCalibrating = r("zoop.today.synthesis.calibrating", "Zoop is still learning your baseline, a few more nights.")

    // MARK: Health monitor

    static let healthAllTypical = r("zoop.today.health.allTypical", "All vitals in your range")
    static func healthOutside(_ n: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.today.health.outside", defaultValue: "\(n) outside your range")
    }
    static let healthNoData = r("zoop.today.health.noData", "Vitals appear after a night with the strap.")

    // MARK: My Day

    static let activitiesEmpty = r("zoop.today.activities.empty", "Nothing recorded for this day yet.")
    static let activitySleep = r("zoop.today.activity.sleep", "Sleep")
    static let activityNap = r("zoop.today.activity.nap", "Nap")
    static let activityDetected = r("zoop.today.activity.detected", "Workout detected")
    static let activityDetectedHint = r("zoop.today.activity.detectedHint", "Tap to save or dismiss")
    static let editNap = r("zoop.today.activity.editNap", "Edit nap times")
    static let breatheTitle = r("zoop.today.moment.breatheTitle", "Your stress is high right now")
    static let breatheBody = r("zoop.today.moment.breatheBody", "A few minutes of slow breathing usually brings it down.")
    static let breatheAction = r("zoop.today.moment.breatheAction", "Breathe for 3 minutes")
    static let eveningTitle = r("zoop.today.moment.eveningTitle", "Sleep tonight")
    static let bedtime = r("zoop.today.moment.bedtime", "Bedtime")
    static let alarm = r("zoop.today.moment.alarm", "Alarm")
    static let alarmOff = r("zoop.today.moment.alarmOff", "Off")
    static let noBedtime = r("zoop.today.moment.noBedtime", "Needs a few nights")

    // MARK: Check-in

    static let checkInInviteTitle = r("zoop.today.checkIn.inviteTitle", "Tune Recovery to how you feel")
    static let checkInInviteBody = r("zoop.today.checkIn.inviteBody", "Answer one short question each morning and Zoop learns your weighting.")
    static let checkInStart = r("zoop.today.checkIn.start", "Start")
    static let checkInNotNow = r("zoop.today.checkIn.notNow", "Not now")
    static let checkInAskTitle = r("zoop.today.checkIn.askTitle", "How do you feel this morning?")
    static let checkInAskAction = r("zoop.today.checkIn.askAction", "Answer")

    // MARK: Header and status

    static func greeting(_ part: DayPart, name: String) -> LocalizedStringResource {
        switch part {
        case .morning: return LocalizedStringResource("zoop.today.greeting.morning", defaultValue: "Good morning, \(name)")
        case .day: return LocalizedStringResource("zoop.today.greeting.day", defaultValue: "Hello, \(name)")
        case .evening: return LocalizedStringResource("zoop.today.greeting.evening", defaultValue: "Good evening, \(name)")
        }
    }
    static func battery(_ percent: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.today.status.battery", defaultValue: "Battery \(percent)")
    }
    static let batteryCharging = r("zoop.today.status.charging", "Charging")
    static let explain = r("zoop.today.action.explain", "How is this calculated?")
    static let quickActions = r("zoop.today.action.quickActions", "Quick actions")
    static let quickStartWorkout = r("zoop.today.quick.startWorkout", "Start workout")
    static let quickLogWorkout = r("zoop.today.quick.logWorkout", "Log workout")
    static let quickFasting = r("zoop.today.quick.fasting", "Fasting")
    static let quickJournal = r("zoop.today.quick.journal", "Logbook")
    static let quickBreathe = r("zoop.today.quick.breathe", "Breathe")
    static let quickNap = r("zoop.today.quick.nap", "Add nap")
    static let liveHeartRate = r("zoop.today.quick.liveHR", "Live heart rate")
    static let profile = r("zoop.today.action.profile", "Profile and settings")
}

/// The three range verdicts, split out of `MetricVerdict` so the copy switch stays exhaustive.
enum RangeVerdict: Equatable, Sendable {
    case typical, above, below

    var verdict: MetricVerdict {
        switch self {
        case .typical: return .typical
        case .above: return .above
        case .below: return .below
        }
    }
}

/// Which range-judged metric a sentence belongs to.
enum VitalCopyID: Equatable, Sendable { case stress, steps, calories, weight, fitnessAge }

/// The part of the day a greeting names.
enum DayPart: Equatable, Sendable { case morning, day, evening }
