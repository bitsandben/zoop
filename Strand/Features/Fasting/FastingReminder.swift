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
        let id = identifier
        guard FastingPreferences.reminderEnabled, let active else {
            NotificationWork.run { $0.removePendingNotificationRequests(withIdentifiers: [id]) }
            return
        }
        let goalDate = Date(timeIntervalSince1970: TimeInterval(active.startTs + active.goalSec))
        let delay = goalDate.timeIntervalSinceNow
        guard delay > 1 else {
            NotificationWork.run { $0.removePendingNotificationRequests(withIdentifiers: [id]) }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: FastingStrings.reminderTitle)
        content.body = String(localized: FastingStrings.reminderBody(
            FastingFormat.duration(TimeInterval(active.goalSec))))
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        // Replace off the main thread, once the authorization status is known (the reminder needs a decided one).
        NotificationWork.withSettings { center, settings in
            center.removePendingNotificationRequests(withIdentifiers: [id])
            guard settings.authorizationStatus != .notDetermined else { return }
            center.add(request)
        }
    }
}
#endif
