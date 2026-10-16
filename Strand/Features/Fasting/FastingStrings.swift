#if os(iOS)
import Foundation
import StrandAnalytics

// MARK: - Fasting copy (zoop.fasting.* catalogue entries)
//
// Every user-visible fasting string, keyed so DE and EN live in Strand/Resources/Localizable.xcstrings.
// The view model picks the resource; views only render it.

enum FastingStrings {
    private static func r(_ key: StaticString, _ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: value)
    }

    static let title = r("zoop.fasting.title", "Fasting")

    // Timer
    static let notFasting = r("zoop.fasting.idle.title", "Not fasting")
    static func lastEnded(_ when: String) -> LocalizedStringResource {
        r("zoop.fasting.idle.lastEnded", "Last fast ended \(when)")
    }
    static func since(_ time: String) -> LocalizedStringResource { r("zoop.fasting.since", "Since \(time)") }
    static func goalAt(_ time: String) -> LocalizedStringResource { r("zoop.fasting.goalAt", "Goal \(time)") }
    static func ofGoal(_ goal: String) -> LocalizedStringResource { r("zoop.fasting.ofGoal", "of \(goal)") }
    static func remaining(_ left: String) -> LocalizedStringResource { r("zoop.fasting.remaining", "\(left) to go") }
    static let goalReached = r("zoop.fasting.goalReached", "Goal reached")
    static let phaseNote = r("zoop.fasting.phase.note", "Phases are rough time guides, not measurements.")

    static func phase(_ phase: FastingPhase) -> LocalizedStringResource {
        switch phase {
        case .afterMeal: return r("zoop.fasting.phase.afterMeal", "After eating")
        case .fasted: return r("zoop.fasting.phase.fasted", "Fasted")
        case .long: return r("zoop.fasting.phase.long", "Long fast")
        case .extended: return r("zoop.fasting.phase.extended", "Extended fast")
        }
    }

    // Plan
    static let planTitle = r("zoop.fasting.plan.title", "Plan")
    static func ratio(fasting: Int, eating: Int) -> LocalizedStringResource {
        r("zoop.fasting.plan.ratio", "\(fasting):\(eating)")
    }
    static let omad = r("zoop.fasting.plan.omad", "One meal a day")
    static let custom = r("zoop.fasting.plan.custom", "Custom")
    static func split(fasting: Int, eating: Int) -> LocalizedStringResource {
        r("zoop.fasting.plan.split", "\(fasting) h fasting · \(eating) h eating")
    }
    static func customHours(_ hours: Int) -> LocalizedStringResource {
        r("zoop.fasting.plan.customHours", "\(hours) h fasting")
    }

    // Eating window and cycle
    static let timeToFast = r("zoop.fasting.timeToFast", "Time to fast")
    static func nextFastAt(_ when: String) -> LocalizedStringResource { r("zoop.fasting.nextAt", "Next fast \(when)") }
    static let windowLeft = r("zoop.fasting.window.left", "left to eat")
    static func windowClosesIn(_ left: String) -> LocalizedStringResource {
        r("zoop.fasting.window.closesIn", "Eating window closes in \(left)")
    }
    static func windowOpened(_ time: String) -> LocalizedStringResource { r("zoop.fasting.window.opened", "Open since \(time)") }
    static func windowClosesAt(_ time: String) -> LocalizedStringResource { r("zoop.fasting.window.closesAt", "Closes \(time)") }
    static func windowClosedAt(_ time: String) -> LocalizedStringResource {
        r("zoop.fasting.window.closedAt", "Eating window closed at \(time)")
    }
    static let firstMeal = r("zoop.fasting.window.firstMeal", "First meal")
    static let lastMeal = r("zoop.fasting.window.lastMeal", "Last meal")
    static let windowEditTitle = r("zoop.fasting.window.editTitle", "Edit eating window")
    static let windowEditNote = r("zoop.fasting.window.editNote",
                                  "Moves the end of the fast before and the start of the fast after.")

    // Schedule
    static let scheduleTitle = r("zoop.fasting.schedule.title", "Schedule")
    static let flexibleTiming = r("zoop.fasting.schedule.flexible", "Flexible: the eating window starts when you end a fast.")
    static func fixedTiming(_ time: String) -> LocalizedStringResource {
        r("zoop.fasting.schedule.fixed", "Fasting starts daily at \(time)")
    }
    static let modeLabel = r("zoop.fasting.schedule.mode", "Start")
    static let modeFlexible = r("zoop.fasting.schedule.mode.flexible", "Flexible")
    static let modeFixed = r("zoop.fasting.schedule.mode.fixed", "Fixed time")
    static let fixedStartLabel = r("zoop.fasting.schedule.startAt", "Fast starts at")
    static let flexibleNote = r("zoop.fasting.schedule.flexibleNote",
                                "After each fast, the eating window lasts as long as your plan allows.")
    static let fixedNote = r("zoop.fasting.schedule.fixedNote", "The eating window closes when your next fast is due.")
    static let autoStartToggle = r("zoop.fasting.schedule.autoStart", "Start the next fast automatically")
    static let autoStartNote = r("zoop.fasting.schedule.autoStartNote",
                                 "When the eating window closes, Zoop starts the fast from that time.")
    static let showOnToday = r("zoop.fasting.schedule.showOnToday", "Show on Today")
    static let remindersTitle = r("zoop.fasting.reminders.title", "Notifications")
    static let closingReminderToggle = r("zoop.fasting.reminder.closing.toggle", "Eating window closes in 30 minutes")
    static let startReminderToggle = r("zoop.fasting.reminder.start.toggle", "Time to start fasting")
    static let closingReminderTitle = r("zoop.fasting.reminder.closing.title", "Eating window closing soon")
    static func closingReminderBody(_ left: String) -> LocalizedStringResource {
        r("zoop.fasting.reminder.closing.body", "Your eating window closes in \(left).")
    }
    static let startReminderTitle = r("zoop.fasting.reminder.start.title", "Time to fast")
    static let startReminderBody = r("zoop.fasting.reminder.start.body",
                                     "Your eating window has closed. Start your fast in Zoop.")
    static let startReminderAutoBody = r("zoop.fasting.reminder.start.autoBody",
                                         "Your eating window has closed; Zoop starts your fast from now.")
    static let reminderToggle = r("zoop.fasting.reminder.toggle", "Notify me when the goal is reached")
    static let reminderDenied = r("zoop.fasting.reminder.denied", "Notifications for Zoop are off in iOS Settings.")
    static let reminderTitle = r("zoop.fasting.reminder.title", "Fasting goal reached")
    static func reminderBody(_ duration: String) -> LocalizedStringResource {
        r("zoop.fasting.reminder.body", "You have fasted for \(duration).")
    }

    // Week and consistency
    static let weekTitle = r("zoop.fasting.week.title", "This week")
    static let weekEmpty = r("zoop.fasting.week.empty", "No fasts logged this week.")
    static func weekTakeaway(met: Int, days: Int) -> LocalizedStringResource {
        r("zoop.fasting.week.takeaway", "Goal reached on \(met) of \(days) days")
    }
    static let streakLabel = r("zoop.fasting.streak.label", "Streak")
    static func streakValue(_ days: Int) -> LocalizedStringResource { r("zoop.fasting.streak.value", "\(days) days") }
    static let consistencyLabel = r("zoop.fasting.consistency.label", "Last 30 days")
    static func consistencyValue(met: Int, of days: Int) -> LocalizedStringResource {
        r("zoop.fasting.consistency.value", "\(met) of \(days) days")
    }

    // History
    static let historyTitle = r("zoop.fasting.history.title", "History")
    static let historyEmpty = r("zoop.fasting.history.empty", "Your finished fasts and eating windows appear here.")
    static let historyFast = r("zoop.fasting.history.fast", "Fast")
    static let historyWindow = r("zoop.fasting.history.window", "Eating window")
    static let legendFasting = r("zoop.fasting.legend.fasting", "Fasting")
    static let legendEating = r("zoop.fasting.legend.eating", "Eating window")

    // Stats
    static let statsEmpty = r("zoop.fasting.stats.empty", "Finish a fast to see your averages.")
    static let statAverage = r("zoop.fasting.stats.average", "Average fast")
    static func statAverageWindow(_ d: String) -> LocalizedStringResource {
        r("zoop.fasting.stats.averageWindow", "Eating window \(d)")
    }
    static let statLongest = r("zoop.fasting.stats.longest", "Longest fast")
    static let statAdherence = r("zoop.fasting.stats.adherence", "Plan adherence")
    static func historyGoal(_ goal: String) -> LocalizedStringResource { r("zoop.fasting.history.goal", "Goal \(goal)") }

    // Edit sheet
    static let editTitle = r("zoop.fasting.edit.title", "Edit fast")
    static let startEarlierTitle = r("zoop.fasting.startEarlier", "Started earlier")
    static let started = r("zoop.fasting.edit.start", "Started")
    static let ended = r("zoop.fasting.edit.end", "Ended")
    static let stillRunning = r("zoop.fasting.edit.running", "Still fasting")

    static func validation(_ v: FastingValidation) -> LocalizedStringResource? {
        switch v {
        case .ok: return nil
        case .endBeforeStart: return r("zoop.fasting.error.endBeforeStart", "The end has to be after the start.")
        case .inFuture: return r("zoop.fasting.error.inFuture", "Times can't be in the future.")
        case .tooLong: return r("zoop.fasting.error.tooLong", "Fasts longer than 72 hours aren't logged.")
        case .overlaps: return r("zoop.fasting.error.overlaps", "This overlaps another logged fast.")
        }
    }
    static let saveFailed = r("zoop.fasting.error.save", "The fast couldn't be saved.")

    // Patterns
    static let patternsTitle = r("zoop.fasting.patterns.title", "And your body?")
    static func notEnough(fasting: Int, other: Int, needed: Int) -> LocalizedStringResource {
        r("zoop.fasting.patterns.notEnough",
          "Not enough data yet: \(fasting) fasting nights and \(other) other nights, \(needed) of each needed.")
    }
    static let noClearDifference = r("zoop.fasting.patterns.noClear", "No clear difference")
    static func onFastingNights(_ delta: String) -> LocalizedStringResource {
        r("zoop.fasting.patterns.difference", "\(delta) on fasting nights")
    }
    static func sample(fasting: Int, other: Int) -> LocalizedStringResource {
        r("zoop.fasting.patterns.sample", "n = \(fasting) fasting / \(other) other nights")
    }
    static let patternsNote = r("zoop.fasting.patterns.note", "Observational: other habits can explain a difference.")
    static let outcomeRestingHR = r("zoop.fasting.patterns.rhr", "Overnight resting HR")
    static let outcomeHRV = r("zoop.fasting.patterns.hrv", "Overnight HRV")
    static let outcomeRecovery = r("zoop.fasting.patterns.recovery", "Next-morning recovery")

    // What the strap can't measure
    static let footnote = r("zoop.fasting.footnote", "The strap can't measure blood glucose, ketones or insulin.")
    static let aboutTitle = r("zoop.fasting.about.title", "About fasting in Zoop")
    static let aboutPhases = r("zoop.fasting.about.phases",
                               "Phase names only describe the time since your last meal; Zoop doesn't measure your metabolism.")
    static let aboutEvidence = r("zoop.fasting.about.evidence",
                                 "In trials, time-restricted eating did not beat plain calorie restriction for weight loss (Lowe 2020, Liu 2022).")
    static let aboutPatterns = r("zoop.fasting.about.patterns",
                                 "Body patterns compare nights inside a logged fast with nights without one and always show both counts.")

    // Shortcuts
    static let intentStarted = r("zoop.fasting.intent.started", "Fast started.")
    static let intentAlreadyRunning = r("zoop.fasting.intent.alreadyRunning", "A fast is already running.")
    static func intentStopped(_ duration: String) -> LocalizedStringResource {
        r("zoop.fasting.intent.stopped", "Fast ended after \(duration).")
    }
    static func intentStoppedWindow(_ duration: String, _ until: String) -> LocalizedStringResource {
        r("zoop.fasting.intent.stoppedWindow", "Fast ended after \(duration). Eating window open until \(until).")
    }
    static func intentStatusFasting(_ elapsed: String, _ goal: String) -> LocalizedStringResource {
        r("zoop.fasting.intent.status.fasting", "You have fasted for \(elapsed); goal at \(goal).")
    }
    static func intentStatusGoalReached(_ elapsed: String) -> LocalizedStringResource {
        r("zoop.fasting.intent.status.goalReached", "You have fasted for \(elapsed) and reached your goal.")
    }
    static let intentNotRunning = r("zoop.fasting.intent.notRunning", "No fast is running.")
    static let intentUnavailable = r("zoop.fasting.intent.unavailable", "Open Zoop once, then try again.")
}
#endif
