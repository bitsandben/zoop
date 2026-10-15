#if os(iOS)
import Foundation
import StrandAnalytics

// MARK: - Proactive coach copy (zoop.coach.* catalogue entries)
//
// Every string the morning brief, its suggestions and the Today card show. Suggestions are stored as
// text, so these are resolved once when the brief is generated; the reason code stays alongside so a
// copy change never breaks the dismissal feedback.

enum CoachStrings {
    private static func r(_ key: StaticString, _ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: value)
    }

    private static func s(_ resource: LocalizedStringResource) -> String { String(localized: resource) }

    // MARK: Card, buttons, history

    static let cardTitle = r("zoop.coach.today.title", "Coach")
    static let accept = r("zoop.coach.accept", "Accept")
    static let later = r("zoop.coach.later", "Later")
    static let dismiss = r("zoop.coach.dismiss", "Dismiss")
    static let allAnswered = r("zoop.coach.today.allAnswered", "All set for today.")
    static let historyTitle = r("zoop.coach.history.title", "Suggestions")
    static let historyOpen = r("zoop.coach.history.open", "All suggestions")
    static let historyEmptyTitle = r("zoop.coach.history.empty.title", "No suggestions yet")
    static let historyEmptyMessage = r("zoop.coach.history.empty.message",
                                       "Your coach suggests something each morning after the sync.")

    static func status(_ s: CoachSuggestion, now: Date) -> LocalizedStringResource {
        if s.status == .new, s.isExpired(at: now) { return r("zoop.coach.status.expired", "Expired") }
        switch s.status {
        case .new: return r("zoop.coach.status.new", "Open")
        case .accepted: return r("zoop.coach.status.accepted", "Accepted")
        case .dismissed: return r("zoop.coach.status.dismissed", "Dismissed")
        case .done: return r("zoop.coach.status.done", "Done")
        }
    }

    // MARK: Push and reminders

    static var pushTitle: String { s(r("zoop.coach.push.title", "Good morning")) }
    static var bedReminderTitle: String { s(r("zoop.coach.remind.bed.title", "Bedtime in 30 minutes")) }
    static func bedReminderBody(_ time: String) -> String {
        s(r("zoop.coach.remind.bed.body", "You planned to be in bed by \(time)."))
    }
    static var fastReminderTitle: String { s(r("zoop.coach.remind.fast.title", "Time to start your fast")) }
    static var fastReminderBody: String { s(r("zoop.coach.remind.fast.body", "Your fasting window starts now.")) }

    // MARK: Brief sentences

    static func readiness(_ band: CoachMorningRules.Readiness, pct: String) -> String? {
        switch band {
        case .high: return s(r("zoop.coach.brief.high", "Recovery \(pct): your body is ready for a hard day."))
        case .medium: return s(r("zoop.coach.brief.medium", "Recovery \(pct): a solid day, not a peak one."))
        case .low: return s(r("zoop.coach.brief.low", "Recovery \(pct): today is for recovering."))
        case .unknown: return nil
        }
    }

    static func slept(_ duration: String) -> String { s(r("zoop.coach.brief.slept", "You slept \(duration).")) }
    static func sleptWithDebt(_ duration: String, debt: String) -> String {
        s(r("zoop.coach.brief.sleptDebt", "You slept \(duration) and carry \(debt) of sleep debt."))
    }
    static func focus(_ title: String) -> String { s(r("zoop.coach.brief.focus", "Focus today: \(title).")) }

    // MARK: Suggestion copy per reason

    /// Values the copy can cite; the gatherer fills what it knows.
    struct Facts {
        var low = "", high = "", routine = "", time = "", debt = ""
    }

    static func title(_ reason: CoachMorningRules.Reason, _ f: Facts) -> String {
        switch reason {
        case .lowRecoveryRest: return s(r("zoop.coach.s.rest.title", "Recovery day"))
        case .plannedRoutineEaseOff: return s(r("zoop.coach.s.easeOff.title", "Go easy on \(f.routine)"))
        case .plannedRoutineGo: return s(r("zoop.coach.s.go.title", "\(f.routine) fits today"))
        case .greenRoutine: return s(r("zoop.coach.s.greenRoutine.title", "\(f.routine) today"))
        case .greenPush: return s(r("zoop.coach.s.push.title", "Push today"))
        case .moderateSession: return s(r("zoop.coach.s.moderate.title", "Moderate session"))
        case .sleepDebtBedtime, .shortNightBedtime: return s(r("zoop.coach.s.bed.title", "In bed by \(f.time)"))
        case .hrvBelowRange: return s(r("zoop.coach.s.hrv.title", "Easy evening"))
        case .highStress: return s(r("zoop.coach.s.stress.title", "Plan a breather"))
        case .fastingNext: return s(r("zoop.coach.s.fastNext.title", "Fast from \(f.time)"))
        case .fastingShorten: return s(r("zoop.coach.s.fastShort.title", "Keep today's fast short"))
        case .steadyDay: return s(r("zoop.coach.s.steady.title", "Keep your rhythm"))
        }
    }

    static func body(_ reason: CoachMorningRules.Reason, _ f: Facts) -> String {
        switch reason {
        case .lowRecoveryRest:
            return s(r("zoop.coach.s.rest.body", "Keep strain between \(f.low) and \(f.high): walk, stretch, nothing hard."))
        case .plannedRoutineEaseOff:
            return s(r("zoop.coach.s.easeOff.body", "Do a lighter version of \(f.routine) or swap it for mobility."))
        case .plannedRoutineGo:
            return s(r("zoop.coach.s.go.body", "Your body is ready; aim for strain \(f.low) to \(f.high)."))
        case .greenRoutine:
            return s(r("zoop.coach.s.greenRoutine.body", "Recovery is high, a good day for a strength session."))
        case .greenPush:
            return s(r("zoop.coach.s.push.body", "Recovery is high; aim for strain \(f.low) to \(f.high)."))
        case .moderateSession:
            return s(r("zoop.coach.s.moderate.body", "Quality over volume today; aim for strain \(f.low) to \(f.high)."))
        case .sleepDebtBedtime:
            return s(r("zoop.coach.s.bedDebt.body", "That pays back part of your \(f.debt) sleep debt."))
        case .shortNightBedtime:
            return s(r("zoop.coach.s.bedShort.body", "Last night was short; an earlier night evens it out."))
        case .hrvBelowRange:
            return s(r("zoop.coach.s.hrv.body", "Your HRV is low; skip alcohol and late caffeine tonight."))
        case .highStress:
            return s(r("zoop.coach.s.stress.body", "Your stress is high; take ten calm minutes this afternoon."))
        case .fastingNext:
            return s(r("zoop.coach.s.fastNext.body", "Your next fast is due then; accept and you get a reminder."))
        case .fastingShorten:
            return s(r("zoop.coach.s.fastShort.body", "Recovery is low; a shorter fast is kinder to your body today."))
        case .steadyDay:
            return s(r("zoop.coach.s.steady.body", "Nothing stands out today: move, eat well, sleep on time."))
        }
    }

    // MARK: Rationale fragments ("based on")

    static func whyRecovery(_ pct: String) -> String { s(r("zoop.coach.why.recovery", "Recovery \(pct)")) }
    static func whyHrv(_ hrv: String, typical: String) -> String {
        s(r("zoop.coach.why.hrv", "HRV \(hrv) ms, typically \(typical) ms"))
    }
    static func whySleep(_ duration: String) -> String { s(r("zoop.coach.why.sleep", "Slept \(duration)")) }
    static func whyDebt(_ debt: String) -> String { s(r("zoop.coach.why.debt", "Sleep debt \(debt)")) }
    static func whyStress(_ level: String) -> String { s(r("zoop.coach.why.stress", "Stress \(level) of 3")) }
    static func whyPlanned(_ name: String) -> String { s(r("zoop.coach.why.planned", "Planned: \(name)")) }
    static var whyFasting: String { s(r("zoop.coach.why.fasting", "Your fasting rhythm")) }
}
#endif
