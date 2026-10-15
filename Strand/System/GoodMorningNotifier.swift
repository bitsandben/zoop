import Foundation
import UserNotifications

// MARK: - Good-morning notification
//
// Once a day, the first time the morning's Recovery is scored after the night ended, post a short
// "Good morning" with Recovery and sleep time. Default on (Automations). Driven by the days
// republish, so it posts after the morning sync rather than at a fixed time.

enum GoodMorningNotifier {
    /// On/off. Absent = on.
    static let enabledKey = "zoop.notif.goodMorning"
    /// The local day the notification last posted for, so it fires at most once per day.
    private static let lastDayKey = "zoop.notif.goodMorningLastDay"
    /// After this local hour the morning message is stale and is skipped for the day.
    static let latestHour = 14

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Pure gate: post when enabled, today's Recovery exists, the night ended today before `now`, it is
    /// still morning, and nothing posted yet today.
    static func shouldPost(enabled: Bool, recovery: Double?, nightEndedToday: Bool, hour: Int,
                           lastPostedDay: String?, today: String) -> Bool {
        enabled && recovery != nil && nightEndedToday && hour < latestHour && lastPostedDay != today
    }

    /// Whether the morning message for `today` already went out (plain or through the coach).
    static func hasPosted(today: String) -> Bool {
        UserDefaults.standard.string(forKey: lastDayKey) == today
    }

    /// Marks the day as announced, so a coach brief and the plain text can never both post.
    static func markPosted(today: String) {
        UserDefaults.standard.set(today, forKey: lastDayKey)
    }

    static func copy(recovery: Double, sleepMinutes: Double?) -> (title: String, body: String) {
        let pct = Int(recovery.rounded())
        let body: String
        if let m = sleepMinutes, m > 0 {
            let h = Int(m) / 60, mm = Int(m) % 60
            body = String(localized: "Recovery \(pct)% · \(h) h \(mm) min sleep. Tap to see what shaped it.")
        } else {
            body = String(localized: "Recovery \(pct)%. Tap to see what shaped it.")
        }
        return (String(localized: "Good morning"), body)
    }

    /// Evaluate and post. Safe to call on every refresh. The day is marked before the asynchronous
    /// permission check, so two evaluations in one turn cannot both post; the mark is rolled back when
    /// notifications are not allowed, so the morning is still announced once they are.
    static func onDayUpdate(today: String, recovery: Double?, sleepMinutes: Double?, nightEndTs: Int?,
                            now: Date = Date()) {
        let d = UserDefaults.standard
        let cal = Calendar.current
        let ended = nightEndTs.map { cal.isDate(Date(timeIntervalSince1970: TimeInterval($0)), inSameDayAs: now)
                                     && TimeInterval($0) <= now.timeIntervalSince1970 } ?? false
        let previousDay = d.string(forKey: lastDayKey)
        guard shouldPost(enabled: isEnabled, recovery: recovery, nightEndedToday: ended,
                         hour: cal.component(.hour, from: now),
                         lastPostedDay: previousDay, today: today),
              let recovery else { return }
        d.set(today, forKey: lastDayKey)
        let copy = copy(recovery: recovery, sleepMinutes: sleepMinutes)
        NotificationWork.withSettings { center, settings in
            guard settings.authorizationStatus == .authorized else {
                if UserDefaults.standard.string(forKey: lastDayKey) == today {
                    UserDefaults.standard.set(previousDay, forKey: lastDayKey)
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "good-morning", content: content, trigger: nil))
        }
    }
}

/// The smart alarm's backup wake notification at the alarm time. Opt-in (default off).
enum AlarmBackupPrefs {
    static let enabledKey = "zoop.notif.alarmBackup"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
}
