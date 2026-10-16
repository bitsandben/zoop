#if os(iOS)
import Foundation
import UserNotifications
import StrandAnalytics

/// The three optional fasting notifications: goal reached, eating window closing in 30 min, and time to
/// start the next fast. Each has one pending request, re-armed from the cycle state after every write
/// and every load (`FastingLog`), so a backdated start or an edited window moves them with it.
@MainActor
enum FastingReminder {
    /// `NotificationPresenter.target(forIdentifier:)` routes the `fasting-` prefix to the Fasting screen.
    static func identifier(_ reminder: FastingPreferences.Reminder) -> String {
        switch reminder {
        case .goal: return "fasting-goal"
        case .closing: return "fasting-window-closing"
        case .start: return "fasting-start"
        }
    }

    enum EnableOutcome { case enabled, denied }

    /// Turns one reminder on, asking for permission once if needed (the WindDownNudge idiom: a denied
    /// permission is reported instead of persisting a toggle the OS will never honour).
    static func setEnabled(_ reminder: FastingPreferences.Reminder, _ on: Bool,
                           state: FastingCycleState, now: Date) async -> EnableOutcome {
        guard on else {
            FastingPreferences.set(reminder, false)
            sync(state: state, now: now)
            return .enabled
        }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        var granted = [.authorized, .provisional, .ephemeral].contains(status)
        if status == .notDetermined {
            granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        FastingPreferences.set(reminder, granted)
        sync(state: state, now: now)
        return granted ? .enabled : .denied
    }

    /// Replaces every pending fasting request with the ones `state` calls for.
    static func sync(state: FastingCycleState, now: Date) {
        let dates = FastingCycle.reminders(state, now: now)
        var requests: [UNNotificationRequest] = []
        func add(_ reminder: FastingPreferences.Reminder, at date: Date?,
                 _ title: LocalizedStringResource, _ body: LocalizedStringResource) {
            guard FastingPreferences.isOn(reminder), let date else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: title)
            content.body = String(localized: body)
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSince(now), repeats: false)
            requests.append(UNNotificationRequest(identifier: identifier(reminder), content: content, trigger: trigger))
        }
        if case .fasting(let interval, _) = state {
            add(.goal, at: dates.goal, FastingStrings.reminderTitle,
                FastingStrings.reminderBody(FastingFormat.duration(interval.goal)))
        }
        add(.closing, at: dates.closing, FastingStrings.closingReminderTitle,
            FastingStrings.closingReminderBody(FastingFormat.duration(FastingCycle.closingLead)))
        add(.start, at: dates.start, FastingStrings.startReminderTitle,
            FastingPreferences.autoStart ? FastingStrings.startReminderAutoBody : FastingStrings.startReminderBody)

        let ids = FastingPreferences.Reminder.allCases.map(identifier)
        let pending = requests
        // Replace off the main thread, once the authorization status is known (a reminder needs a decided one).
        NotificationWork.withSettings { center, settings in
            center.removePendingNotificationRequests(withIdentifiers: ids)
            guard settings.authorizationStatus != .notDetermined else { return }
            pending.forEach { center.add($0) }
        }
    }
}
#endif
