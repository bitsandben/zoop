#if os(iOS)
import Foundation
import StrandAnalytics

// MARK: - Proactive coach copy (zoop.coach.* catalogue entries)
//
// Every string the morning brief, its suggestions and the Today card show. The rules in StrandAnalytics
// return reason codes, actions and numbers only; the sentences are built here, in the app language.
// Suggestions are stored as text, so these are resolved once when the brief is generated; the reason
// code stays alongside so a copy change never breaks the dismissal feedback.

enum CoachStrings {
    private static func r(_ key: StaticString, _ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: value)
    }

    private static func s(_ resource: LocalizedStringResource) -> String { String(localized: resource) }

    // MARK: Card, buttons, history

    static let cardTitle = r("zoop.coach.today.title", "Coach")
    static let later = r("zoop.coach.later", "Later")
    static let dismiss = r("zoop.coach.dismiss", "Dismiss")
    static let allAnswered = r("zoop.coach.today.allAnswered", "All set for today.")
    /// The compact card's quiet second line ("2 suggestions").
    static func pending(_ n: Int) -> LocalizedStringResource {
        n == 1 ? r("zoop.coach.today.pendingOne", "1 suggestion")
            : LocalizedStringResource("zoop.coach.today.pending", defaultValue: "\(n) suggestions")
    }
    static let historyTitle = r("zoop.coach.history.title", "Suggestions")
    static let historyOpen = r("zoop.coach.history.open", "All suggestions")
    static let historyEmptyTitle = r("zoop.coach.history.empty.title", "No suggestions yet")
    static let historyEmptyMessage = r("zoop.coach.history.empty.message",
                                       "Your coach suggests something each morning after the sync.")

    /// The main answer, named after what accepting actually does.
    static func accept(_ action: CoachSuggestion.Action) -> LocalizedStringResource {
        switch action {
        case .routine: return r("zoop.coach.accept.plan", "Plan it")
        case .bedtime, .breathe, .fastingStart: return r("zoop.coach.accept.remind", "Remind me")
        case .none, .strainTarget: return r("zoop.coach.accept.ok", "Got it")
        }
    }

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
    static var breatheReminderTitle: String { s(r("zoop.coach.remind.breathe.title", "Time for a breather")) }
    static var breatheReminderBody: String {
        s(r("zoop.coach.remind.breathe.body", "Three slow minutes before your usual stress peak."))
    }

    // MARK: Brief sentences

    static func focus(_ title: String) -> String { s(r("zoop.coach.brief.focus", "Focus today: \(title).")) }

    // MARK: Suggestion copy per reason

    /// Values the copy can cite, already formatted.
    struct Facts {
        var routine = "", time = ""
        /// The strain band in the user's own Effort scale ("8–12"), empty when unknown.
        var target = ""
    }

    static func title(_ reason: CoachMorningRules.Reason, _ f: Facts) -> String {
        switch reason {
        case .illnessRest: return s(r("zoop.coach.s.illness.title", "Rest day"))
        case .lowRecoveryRest: return s(r("zoop.coach.s.rest.title", "Recovery day"))
        case .poorSleepEasy: return s(r("zoop.coach.s.poorSleep.title", "Take it easy today"))
        case .plannedRoutineEaseOff: return s(r("zoop.coach.s.easeOff.title", "Go easy on \(f.routine)"))
        case .hrvTrendCaution: return s(r("zoop.coach.s.caution.title", "Hold back a little"))
        case .loadDeload: return s(r("zoop.coach.s.deload.title", "Lighter day"))
        case .routineBackOnTrack: return s(r("zoop.coach.s.backOnTrack.title", "\(f.routine) is due today"))
        case .routineMissed: return s(r("zoop.coach.s.missed.title", "Remember \(f.routine)"))
        case .plannedRoutineGo: return s(r("zoop.coach.s.go.title", "\(f.routine) fits today"))
        case .greenRoutine: return s(r("zoop.coach.s.greenRoutine.title", "\(f.routine) today"))
        case .greenPush: return s(r("zoop.coach.s.push.title", "Push today"))
        case .trendGreenLight: return s(r("zoop.coach.s.trendGreen.title", "Green light today"))
        case .moderateSession: return s(r("zoop.coach.s.moderate.title", "Moderate session"))
        case .sleepDebtBedtime, .shortNightBedtime, .bedtimeRegularity: return s(r("zoop.coach.s.bed.title", "In bed by \(f.time)"))
        case .stressPeakBreathe: return s(r("zoop.coach.s.breathe.title", "Breather at \(f.time)"))
        case .highStress: return s(r("zoop.coach.s.stress.title", "Plan a breather"))
        case .hrvBelowRange: return s(r("zoop.coach.s.hrv.title", "Easy evening"))
        case .fastingBreak: return s(r("zoop.coach.s.fastBreak.title", "Consider ending your fast"))
        case .steadyDay: return s(r("zoop.coach.s.steady.title", "Keep your rhythm"))
        }
    }

    /// One sentence; the strain band closes it when the action carries one.
    static func body(_ reason: CoachMorningRules.Reason, _ f: Facts) -> String {
        let base = bodyBase(reason, f)
        return f.target.isEmpty
            ? s(r("zoop.coach.body.plain", "\(base)."))
            : s(r("zoop.coach.body.target", "\(base) (strain \(f.target))."))
    }

    private static func bodyBase(_ reason: CoachMorningRules.Reason, _ f: Facts) -> String {
        switch reason {
        case .illnessRest: return s(r("zoop.coach.b.illness", "Skip training, drink plenty and get to bed early"))
        case .lowRecoveryRest: return s(r("zoop.coach.b.rest", "Walk and stretch, nothing hard"))
        case .poorSleepEasy: return s(r("zoop.coach.b.poorSleep", "Keep training light and skip hard intervals"))
        case .plannedRoutineEaseOff: return s(r("zoop.coach.b.easeOff", "Do a lighter version of \(f.routine) or swap it for mobility"))
        case .hrvTrendCaution: return s(r("zoop.coach.b.caution", "Train, but keep it controlled and skip max efforts"))
        case .loadDeload: return s(r("zoop.coach.b.deload", "Your week is already heavy, so make today an easy one"))
        case .routineBackOnTrack: return s(r("zoop.coach.b.backOnTrack", "Get \(f.routine) done today to get back into your rhythm"))
        case .routineMissed: return s(r("zoop.coach.b.missed", "Your body is ready, a good day to catch up on \(f.routine)"))
        case .plannedRoutineGo: return s(r("zoop.coach.b.go", "Your body is ready for \(f.routine)"))
        case .greenRoutine: return s(r("zoop.coach.b.greenRoutine", "Recovery is high, a good day for a strength session"))
        case .greenPush: return s(r("zoop.coach.b.push", "A good day for a hard session"))
        case .trendGreenLight: return s(r("zoop.coach.b.trendGreen", "Your body is trending up, a good day to push"))
        case .moderateSession: return s(r("zoop.coach.b.moderate", "Quality over volume today"))
        case .sleepDebtBedtime: return s(r("zoop.coach.b.bedDebt", "That pays back part of your sleep debt"))
        case .shortNightBedtime: return s(r("zoop.coach.b.bedShort", "An earlier night evens out the short one"))
        case .bedtimeRegularity: return s(r("zoop.coach.b.bedRegular", "A steady bedtime helps you recover"))
        case .stressPeakBreathe: return s(r("zoop.coach.b.breathe", "Three minutes of slow breathing before your usual stress peak"))
        case .highStress: return s(r("zoop.coach.b.stress", "Take ten calm minutes this afternoon"))
        case .hrvBelowRange: return s(r("zoop.coach.b.hrv", "Skip alcohol and late caffeine tonight"))
        case .fastingBreak: return s(r("zoop.coach.b.fastBreak", "Break it with a proper meal and drink plenty of water"))
        case .steadyDay: return s(r("zoop.coach.b.steady", "Nothing stands out today, so move, eat well and sleep on time"))
        }
    }

    // MARK: Because (the numbers a suggestion rests on)

    /// "Because your recovery is 31 % and you slept only 5 h 10 min."
    static func because(_ clauses: [String]) -> String {
        guard !clauses.isEmpty else { return "" }
        let list = clauses.formatted(.list(type: .and).locale(AppLanguage.activeLocale))
        return s(r("zoop.coach.because", "Because \(list)."))
    }

    static func clause(_ e: CoachMorningRules.Evidence, format: CoachEvidenceFormat) -> String {
        switch e {
        case .recovery(let pct):
            return s(r("zoop.coach.why.recovery", "your recovery is \(format.number(pct))"))
        case .sleep(let min):
            return s(r("zoop.coach.why.sleep", "you slept only \(format.duration(min))"))
        case .sleepDebt(let min):
            return s(r("zoop.coach.why.debt", "you carry \(format.duration(min)) of sleep debt"))
        case .hrvTrend(let days, let delta) where delta < 0:
            return s(r("zoop.coach.why.hrvDown", "your HRV has been below your normal for \(days) days (\(format.signed(delta)))"))
        case .hrvTrend(let days, let delta):
            return s(r("zoop.coach.why.hrvUp", "your HRV has been above your normal for \(days) days (\(format.signed(delta)))"))
        case .rhrTrend(let days, let delta) where delta > 0:
            return s(r("zoop.coach.why.rhrUp", "your resting heart rate has been above your normal for \(days) days (\(format.signed(delta)))"))
        case .rhrTrend(let days, let delta):
            return s(r("zoop.coach.why.rhrDown", "your resting heart rate has been below your normal for \(days) days (\(format.signed(delta)))"))
        case .hrvToday(let ms, let typical):
            return s(r("zoop.coach.why.hrvToday", "your HRV is \(format.number(ms)) ms, typically \(format.number(typical)) ms"))
        case .load(let pct):
            return s(r("zoop.coach.why.load", "your training load this week is \(format.percent(pct)) of your normal"))
        case .missedRoutine(let missed, let planned):
            return s(r("zoop.coach.why.missed", "you skipped \(missed) of \(planned) planned sessions in the last two weeks"))
        case .planned(let name):
            return s(r("zoop.coach.why.planned", "\(name) is on your plan"))
        case .bedtimeDrift(let last, let usual):
            return s(r("zoop.coach.why.bedDrift", "last night started at \(format.clock(last)) instead of around \(format.clock(usual))"))
        case .stressPeak(let hour):
            return s(r("zoop.coach.why.stressPeak", "your stress usually peaks around \(format.clock(hour * 60))"))
        case .stressYesterday(let level):
            return s(r("zoop.coach.why.stress", "your stress yesterday was \(format.decimal(level)) of 3"))
        case .fasting(let hours):
            return s(r("zoop.coach.why.fasting", "you have been fasting for \(hours) hours"))
        case .illness:
            return s(r("zoop.coach.why.illness", "several of your vitals are off your normal"))
        }
    }
}

/// Number formatting for the "because" clauses, in the app locale. A value type so the composer can
/// hand one formatter to every clause.
struct CoachEvidenceFormat {
    let clock: (Int) -> String
    let duration: (Int) -> String

    func percent(_ v: Int) -> String { ZoopNumber.percent(Double(v)) }
    func signed(_ v: Int) -> String { ZoopNumber.percent(Double(v), signed: true) }
    func number(_ v: Int) -> String { ZoopNumber.decimal(Double(v), digits: 0) }
    func decimal(_ v: Double) -> String { ZoopNumber.decimal(v, digits: 1) }
}
#endif
