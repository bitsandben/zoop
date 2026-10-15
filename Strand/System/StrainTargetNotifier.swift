import Foundation
import UserNotifications

// MARK: - Target-strain notification
//
// Opt-in, default-OFF nudge: once per day, when the day's Effort reaches the low end of today's
// recovery-derived optimal strain band, post an "optimal strain reached" notification. The copy is
// Zoop's own, and the target is Zoop's own recovery-to-strain band.
//
// The gate runs on the 0-21 coupled axis: stored Effort (0-100) is converted with
// UnitFormatter.effortValue(_, .whoop) at the call site and the target is the band's lowerBound.
// Day strain is a per-pass rollup, so it fires on the first pass at/after the crossing. Once-per-day
// dedupe via a persisted day string, as in BatteryNotifier.
enum StrainTargetNotifier {
    private static let lastDayKey = "behavior.strainTargetLastDay"

    /// Pure, testable policy and copy (pinned by StrainTargetPolicyTests).
    enum StrainTargetPolicy {
        /// Fires at most once per day: enabled, day strain and target both known and on the same 0-21 axis,
        /// strain at/above target, and not already posted for `today`. A nil target (recovery unknown) never fires.
        static func shouldNotify(enabled: Bool,
                                 dayStrain: Double?,
                                 target: Double?,
                                 lastNotifiedDay: String?,
                                 today: String) -> Bool {
            guard enabled, let dayStrain, let target else { return false }
            return dayStrain >= target && lastNotifiedDay != today
        }

        /// Title and body for the nudge; `target` is the optimal-band low on the 0-21 axis.
        static func copy(target: Int) -> (title: String, body: String) {
            (String(localized: "Optimal strain reached"),
             String(localized: "You've hit today's optimal strain target of \(target). Nice work — your recovery earned it."))
        }
    }

    /// Ask up front (when the user enables the nudge) so the system dialog appears at a predictable moment.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Runs the policy against today's values and posts at most one notification per day. `dayStrain21`
    /// and `target21` are on the 0-21 axis. No-op when the policy fails, so it can fire on every
    /// republish. The day marker advances only after an authorized post, so a denied day still notifies
    /// once notifications are re-enabled.
    static func onDayUpdate(day: String, dayStrain21: Double?, target21: Int?, enabled: Bool) {
        let d = UserDefaults.standard
        guard StrainTargetPolicy.shouldNotify(enabled: enabled,
                                              dayStrain: dayStrain21,
                                              target: target21.map(Double.init),
                                              lastNotifiedDay: d.string(forKey: lastDayKey),
                                              today: day) else { return }
        // Non-nil: shouldNotify required a target.
        let copy = StrainTargetPolicy.copy(target: target21!)
        let center = UNUserNotificationCenter.current()
        // Authorization is requested once via requestAuthorization(); here only the status is checked.
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "strain-target", content: content, trigger: nil))
            UserDefaults.standard.set(day, forKey: lastDayKey)
        }
    }
}
