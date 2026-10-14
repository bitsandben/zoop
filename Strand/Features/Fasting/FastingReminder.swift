#if os(iOS)
import Foundation
import UserNotifications
import StrandAnalytics
import WhoopStore

/// The optional "goal reached" notification. One pending request at a time, re-armed from the running
/// fast whenever it starts, is edited, or ends, so a backdated start moves the notification with it.
@MainActor
enum FastingReminder {
    /// `NotificationPresenter.target(forIdentifier:)` routes this prefix to the Fasting screen.
    static let identifier = "fasting-goal"

    enum EnableOutcome { case enabled, denied }

    /// Turns the reminder on, asking for permission once if needed (the WindDownNudge idiom: a denied
    /// permission is reported instead of persisting a toggle the OS will never honour).
    static func setEnabled(_ on: Bool, active: FastingSessionRow?) async -> EnableOutcome {
        guard on else {
            FastingPreferences.reminderEnabled = false
            sync(active: nil)
            return .enabled
        }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        var granted = [.authorized, .provisional, .ephemeral].contains(status)
        if status == .notDetermined {
            granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        FastingPreferences.reminderEnabled = granted
        sync(active: active)
        return granted ? .enabled : .denied
    }

    /// Replaces the pending request with one at `active`'s goal time, or clears it.
    static func sync(active: FastingSessionRow?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard FastingPreferences.reminderEnabled, let active else { return }
        let goalDate = Date(timeIntervalSince1970: TimeInterval(active.startTs + active.goalSec))
        let delay = goalDate.timeIntervalSinceNow
        guard delay > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: FastingStrings.reminderTitle)
        content.body = String(localized: FastingStrings.reminderBody(
            FastingFormat.duration(TimeInterval(active.goalSec))))
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}
#endif
