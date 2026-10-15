import Foundation
import StrandAnalytics
import StrandDesign

/// Words for the coach-built plan, its weekly updates and routine progression, in the app language.
/// One place, so the plan card, the calendar, the update card and the notification say it the same way.
enum PlanFormat {

    /// A catalogue string by key, in the app language.
    static func t(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: AppLanguage.activeLocale, arguments: args)
    }

    private static var calendar: Calendar {
        var c = Calendar.current
        c.locale = AppLanguage.activeLocale
        return c
    }

    /// "Montag" for a `Calendar` weekday (1 = Sunday).
    static func weekday(_ day: Int) -> String {
        calendar.standaloneWeekdaySymbols[max(1, min(7, day)) - 1]
    }

    /// "Mo." for a `Calendar` weekday.
    static func shortWeekday(_ day: Int) -> String {
        calendar.shortStandaloneWeekdaySymbols[max(1, min(7, day)) - 1]
    }

    static func minutes(_ value: Int) -> String {
        Duration.seconds(value * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)
            .locale(AppLanguage.activeLocale))
    }

    /// "45 Min. · 18:00" / "45 min · Yoga".
    static func sessionDetail(_ session: PlanSession) -> String {
        [minutes(session.minutes), session.time ?? WorkoutSource.displaySport(session.sport)]
            .joined(separator: " · ")
    }

    /// "10. Okt. 2026" from a yyyy-MM-dd key.
    static func day(_ key: String) -> String {
        guard let date = date(key) else { return key }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguage.activeLocale))
    }

    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: Weekly update sentences

    /// "Du hast Kraft B zweimal ausgelassen → auf Mittwoch verschoben".
    static func sentence(_ item: PlanWeeklyReview.Item, sessions: [PlanSession]) -> String {
        let session = sessions.first { $0.id == item.change.sessionId }
        let title = session?.title ?? ""
        let reason: String
        switch item.reason {
        case .missedTwice: reason = t("zoop.plan.reason.missedTwice", title)
        case .lowRecovery(let days): reason = t("zoop.plan.reason.lowRecovery", "\(days)")
        case .lowHRV(let days): reason = t("zoop.plan.reason.lowHRV", "\(days)")
        case .loadHigh: reason = t("zoop.plan.reason.loadHigh")
        case .steady(let weeks): reason = t("zoop.plan.reason.steady", "\(weeks)")
        }
        let change: String
        switch item.change {
        case .move(_, _, let to): change = t("zoop.plan.change.move", weekday(to))
        case .shorten(_, let from, let to), .lengthen(_, let from, let to):
            change = t("zoop.plan.change.minutes", title, "\(to)", "\(from)")
        case .addSet: change = t("zoop.plan.change.addSet", title)
        }
        return "\(reason) → \(change)"
    }

    // MARK: Routine progression

    /// "Nächstes Mal: 62,5 kg" and friends; nil when there is nothing to say.
    static func nextTime(_ advice: LiftProgression.Advice) -> String {
        switch advice.step {
        case .addWeight(_, let to): return t("zoop.lift.next.weight", kg(to))
        case .addReps(let to): return t("zoop.lift.next.reps", "\(to)")
        case .harderVariant(let reps): return t("zoop.lift.next.harder", "\(reps)")
        case .deload(_, let to): return t("zoop.lift.next.deload", kg(to))
        case .hold:
            if let w = advice.next.weightKg { return t("zoop.lift.next.hold", kg(w)) }
            return t("zoop.lift.next.holdReps")
        }
    }

    static func kg(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(AppLanguage.activeLocale))
    }
}
