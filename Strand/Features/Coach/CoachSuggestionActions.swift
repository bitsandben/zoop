#if os(iOS)
import Foundation
import StrandAnalytics
import UserNotifications

/// What the three answers on a suggestion do. Kept out of the card so the view only forwards taps.
///
/// Accepting carries out the suggestion's action where the app can: a routine lands in today's Lift
/// Log plan, a bedtime arms a one-off wind-down reminder, a fasting start arms a start reminder.
/// Advice the app cannot act on (a strain band, a habit) is recorded as accepted.
@MainActor
enum CoachSuggestionActions {

    /// "Later" hides the suggestion for this long.
    static let snoozeInterval: TimeInterval = 3 * 3600
    /// The bedtime reminder fires this long before the proposed bedtime.
    static let bedtimeLead = 30
    /// Ids keep the existing routing prefixes so a tap opens the sleep planner / fasting screen.
    private static let bedtimeRequestId = "wind-down-nudge-coach"
    private static let fastingRequestId = "fasting-goal-coach-start"

    static func accept(_ s: CoachSuggestion, store: CoachSuggestionStore = .shared, now: Date = Date()) {
        let performed = perform(s.action, now: now)
        store.answer(s.id, status: performed ? .done : .accepted)
    }

    static func later(_ s: CoachSuggestion, store: CoachSuggestionStore = .shared, now: Date = Date()) {
        store.snooze(s.id, until: now.addingTimeInterval(snoozeInterval))
    }

    static func dismiss(_ s: CoachSuggestion, store: CoachSuggestionStore = .shared) {
        store.answer(s.id, status: .dismissed)
    }

    /// True when the app itself carried the action out.
    private static func perform(_ action: CoachSuggestion.Action, now: Date) -> Bool {
        switch action {
        case .none, .strainTarget:
            return false
        case .routine(let programId, _):
            var plan = TrainingPlan.decode(UserDefaults.standard.string(forKey: TrainingPlan.storageKey) ?? "")
            plan.addOnce(programId, on: now)
            // Written through UserDefaults so every `@AppStorage(TrainingPlan.storageKey)` reader updates.
            UserDefaults.standard.set(plan.encoded(), forKey: TrainingPlan.storageKey)
            return true
        case .bedtime(let minute):
            guard let fire = nextOccurrence(of: minute - bedtimeLead, after: now) else { return false }
            schedule(id: bedtimeRequestId, at: fire, title: CoachStrings.bedReminderTitle,
                     body: CoachStrings.bedReminderBody(CoachMorningComposer.clock(minute)))
            return true
        case .fastingStart(let minute, _):
            guard let fire = nextOccurrence(of: minute, after: now) else { return false }
            schedule(id: fastingRequestId, at: fire, title: CoachStrings.fastReminderTitle,
                     body: CoachStrings.fastReminderBody)
            return true
        }
    }

    /// The next time `minuteOfDay` comes round within a day of `now` (a bedtime after midnight belongs
    /// to tonight, not to this morning).
    static func nextOccurrence(of minuteOfDay: Int, after now: Date, calendar: Calendar = .current) -> Date? {
        let m = ((minuteOfDay % 1440) + 1440) % 1440
        let start = calendar.startOfDay(for: now)
        guard let today = calendar.date(byAdding: .minute, value: m, to: start) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// One-off reminder. The permission is not requested here: an accepted suggestion still counts
    /// when notifications are off, it just has no reminder behind it.
    private static func schedule(id: String, at date: Date, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
#endif
