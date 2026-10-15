import Foundation
import UserNotifications

/// Posts the illness early-warning as a macOS notification when the banner goes from clear to
/// raised. Once per local day; the in-app banner stays the live surface. On-device only; the summary
/// is approximate, not a diagnosis.
enum IllnessNotifier {
    private static let lastDayKey = "behavior.illnessLastNotifiedDay"

    /// Ask up front (when the user enables the watch) so the system dialog appears at a predictable moment.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts the early-warning, at most once per local day.
    static func post(_ message: String) {
        let day = dayKey(Date())
        let d = UserDefaults.standard
        guard d.string(forKey: lastDayKey) != day else { return }
        // Mark the day up front so the limit holds even if notifications are declined; never re-prompt.
        d.set(day, forKey: lastDayKey)
        let center = UNUserNotificationCenter.current()
        // Authorization is requested once in requestAuthorization(); here only the status is checked.
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Early warning: take it easy")
            content.subtitle = String(localized: "On-device estimate (approximate), not a diagnosis.")
            content.body = message
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "illness-watch",
                                             content: content, trigger: nil))
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
