import Foundation
import UserNotifications
import StrandAnalytics

/// Surfaces strap battery state as a notification: LOW when the cell reaches the threshold, CHARGED at
/// 100%. Like `IllnessNotifier`: authorization is requested up front when the toggle is enabled, fire time
/// checks status only, and the persisted gate advances even when delivery is deferred. Gated by the user's
/// "Battery alerts" setting (#368).
enum BatteryNotifier {
    private static let lowAlertedKey = "behavior.batteryLowAlerted"
    private static let fullAlertedKey = "behavior.batteryFullAlerted"
    private static let runtimeAlertedKey = "behavior.batteryRuntimeAlerted"
    /// Gates for the two escalation alerts, separate keys on purpose so a latched `lowAlertedKey` or
    /// `runtimeAlertedKey` cannot silence them.
    private static let criticalAlertedKey = "behavior.batteryCriticalAlerted"
    private static let bedtimeAlertedKey = "behavior.batteryBedtimeAlerted"

    /// Epoch seconds of the banked reading `onStrapNotSeen` last warned about. Keyed on the reading so one
    /// stale value cannot re-notify on every wake while a newer low reading still counts (#2556).
    private static let staleAlertedTsKey = "behavior.batteryStaleAlertedTs"

    /// Whether a strap nobody has heard from is worth warning about (#2556). `BatteryAlertPolicy` only judges
    /// percentages the app received over a live connection, so a strap that drains while disconnected crosses
    /// the thresholds unseen. This reads the last banked reading instead, so it can only say "last seen at 11
    /// percent, six hours ago", never a current level. Silent while connected: the live crossings own that case.
    enum StaleBatteryAlertPolicy {
        /// How long out of contact before a low last reading is worth raising.
        static let staleAfterSeconds = 2 * 60 * 60

        struct Decision: Equatable {
            let fire: Bool
            let ageSeconds: Int
        }

        /// How long ago, as a compact label ("6h", "3d"). Plural-free to avoid per-locale plural rules; the age
        /// is never below the two-hour window.
        static func ageLabel(_ seconds: Int) -> String {
            let hours = seconds / 3600
            return hours >= 48 ? "\(hours / 24)d" : "\(hours)h"
        }

        private static let no = Decision(fire: false, ageSeconds: 0)

        /// `alertedForTs` is the reading already alerted for (persisted); a newer low reading is a new fact.
        static func evaluate(lastSocPct: Int?,
                             lastTsSec: Int?,
                             lastCharging: Bool?,
                             nowSec: Int,
                             connected: Bool,
                             alertedForTs: Int?,
                             lowThreshold: Int = BatteryAlertPolicy.lowThreshold,
                             staleAfterSeconds: Int = staleAfterSeconds) -> Decision {
            if connected { return no }
            guard let lastSocPct, let lastTsSec else { return no }
            // Only a confirmed charging reading suppresses, matching the live policy.
            if lastCharging == true { return no }
            if lastSocPct > lowThreshold { return no }
            let age = nowSec - lastTsSec
            // A reading from the future is a clock problem, not a stale strap.
            if age < staleAfterSeconds { return no }
            if alertedForTs == lastTsSec { return no }
            return Decision(fire: true, ageSeconds: age)
        }
    }

    /// Pure crossing-with-hysteresis policy. The `*Alerted` flags are persisted so they survive process death,
    /// and the 25% re-arm band fires the low alert once per discharge cycle despite 14/15% jitter. Full re-arms only below 100.
    enum BatteryAlertPolicy {
        static let lowThreshold = 15
        static let lowRearmAbove = 25
        static let fullThreshold = 100

        /// `charging == nil` means unknown (the low alert still fires; only a confirmed `true` suppresses).
        /// Returns the fire decisions and the next persisted flag state. `clearFull` marks the full re-arm
        /// transition so the notifier can pull the stale "fully charged" notification (#514).
        static func evaluate(pct: Int,
                             charging: Bool?,
                             lowAlerted: Bool,
                             fullAlerted: Bool)
            -> (fireLow: Bool, fireFull: Bool, clearFull: Bool, newLowAlerted: Bool, newFullAlerted: Bool) {
            var low = lowAlerted
            var full = fullAlerted
            // The stale 100%-full note must be cleared when re-arming below the full line.
            let clearFull = fullAlerted && pct < fullThreshold
            // Re-arm only on genuine recovery (pct >= lowRearmAbove), not on charging (#80): the strap reports its
            // charge bit only every ~8 min, so it flickers true/nil, and re-arming on `true` re-fired the low alert
            // while charging.
            if pct >= lowRearmAbove { low = false }
            if pct < fullThreshold { full = false }
            // Fire at most once per genuine crossing.
            let fireLow = !low && pct <= lowThreshold && charging != true
            let fireFull = !full && pct >= fullThreshold
            if fireLow { low = true }
            if fireFull { full = true }
            return (fireLow, fireFull, clearFull, low, full)
        }
    }

    /// Ask up front (when the user enables alerts) so the dialog appears at a predictable moment.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Run the policy on a fresh reading and post at most one notification per crossing. No-op when the
    /// setting is off. The persisted flags are always written back so the gate advances even if delivery is declined.
    static func onBatteryUpdate(pct: Int, charging: Bool?, enabled: Bool) {
        guard enabled else { return }
        let d = UserDefaults.standard
        let result = BatteryAlertPolicy.evaluate(
            pct: pct,
            charging: charging,
            lowAlerted: d.bool(forKey: lowAlertedKey),
            fullAlerted: d.bool(forKey: fullAlertedKey))
        // Advance the gate up front so once-per-crossing holds regardless of authorization or delivery.
        d.set(result.newLowAlerted, forKey: lowAlertedKey)
        d.set(result.newFullAlerted, forKey: fullAlertedKey)
        if result.fireLow {
            post(identifier: "battery-low",
                 title: String(localized: "Low battery"),
                 body: String(localized: "Recharge your WHOOP before tonight."))
        }
        if result.fireFull {
            post(identifier: "battery-full",
                 title: String(localized: "Strap fully charged"),
                 body: String(localized: "Your WHOOP is at 100%."))
        }
        // The strap dropped below 100%: pull the stale "fully charged" note (delivered and pending).
        if result.clearFull {
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: ["battery-full"])
            center.removePendingNotificationRequests(withIdentifiers: ["battery-full"])
        }
    }

    /// Predictive twin of `onBatteryUpdate`: fires on `BatteryEstimator.runtimeAlert` (at or under 24 h,
    /// re-arm at 36 h), once per discharge cycle. The 15% alert remains the net for straps with no usable
    /// estimate (a no-op here). Same gating as #368.
    static func onRuntimeEstimate(remainingHours: Double?, charging: Bool?, enabled: Bool) {
        guard enabled, let remainingHours else { return }
        let d = UserDefaults.standard
        let result = BatteryEstimator.runtimeAlert(remainingHours: remainingHours,
                                                   charging: charging,
                                                   alerted: d.bool(forKey: runtimeAlertedKey))
        d.set(result.newAlerted, forKey: runtimeAlertedKey)
        if result.fire {
            post(identifier: "battery-runtime",
                 title: String(localized: "Strap battery low"),
                 body: String(localized: "\(BatteryEstimator.label(hours: remainingHours)) left on your WHOOP — recharge tonight."))
        }
    }

    /// Warn that a strap last seen low has not been heard from since (#2556). The live crossings need a
    /// connection; this reads the last banked reading, so the copy says "when Zoop last heard from it" and
    /// never names a current percentage.
    static func onStrapNotSeen(lastSocPct: Int?,
                               lastTsSec: Int?,
                               lastCharging: Bool?,
                               nowSec: Int,
                               connected: Bool,
                               enabled: Bool) {
        guard enabled else { return }
        let d = UserDefaults.standard
        let decision = StaleBatteryAlertPolicy.evaluate(
            lastSocPct: lastSocPct,
            lastTsSec: lastTsSec,
            lastCharging: lastCharging,
            nowSec: nowSec,
            connected: connected,
            alertedForTs: d.object(forKey: staleAlertedTsKey) as? Int)
        guard decision.fire, let lastSocPct, let lastTsSec else { return }
        let age = StaleBatteryAlertPolicy.ageLabel(decision.ageSeconds)
        post(identifier: "battery-stale",
             title: String(localized: "WHOOP last seen low"),
             body: String(localized: "\(lastSocPct)% when Zoop last heard from it, \(age) ago. Charge it before tonight."),
             interruptionLevel: .timeSensitive)
        // Persisted after posting, keyed on the reading, so a failed post retries on the next wake.
        d.set(lastTsSec, forKey: staleAlertedTsKey)
    }

    /// Critical low-battery escalation below the 15% alert (at `BatteryEstimator.criticalSocPct`). Its
    /// own `criticalAlertedKey` keeps a latched low/runtime alert from silencing the last hours of
    /// discharge. Self-gates on the setting and fires once per cycle.
    static func onCriticalBattery(pct: Int, charging: Bool?, enabled: Bool) {
        guard enabled else { return }
        let d = UserDefaults.standard
        let result = BatteryEstimator.criticalAlert(pct: pct,
                                                    charging: charging,
                                                    alerted: d.bool(forKey: criticalAlertedKey))
        d.set(result.newAlerted, forKey: criticalAlertedKey)
        if result.fire {
            post(identifier: "battery-critical",
                 title: String(localized: "Charge your WHOOP now"),
                 body: String(localized: "\(pct)% left. The strap stops recording near 10% — it won't capture tonight unless you charge it."),
                 interruptionLevel: .timeSensitive)
        }
    }

    /// Bedtime night-guard: "this won't last the night", delivered while there is time to act. Independent of
    /// `runtimeAlertedKey` (the generic alert may have latched hours earlier) and re-armed every night. `runway`
    /// is nil at cold start (no learned bedtime); the policy stays silent rather than inventing one.
    static func onBedtimeRunway(nowSecOfDay: Int,
                                habitualMidsleepSec: Int?,
                                typicalSleepHours: Double?,
                                usableRemainingHours: Double?,
                                charging: Bool?,
                                enabled: Bool) {
        guard enabled else { return }
        let d = UserDefaults.standard
        let result = BatteryEstimator.bedtimeAlert(nowSecOfDay: nowSecOfDay,
                                                   habitualMidsleepSec: habitualMidsleepSec,
                                                   typicalSleepHours: typicalSleepHours,
                                                   usableRemainingHours: usableRemainingHours,
                                                   charging: charging,
                                                   alerted: d.bool(forKey: bedtimeAlertedKey))
        d.set(result.newAlerted, forKey: bedtimeAlertedKey)
        if result.fire, let runway = result.runway {
            post(identifier: "battery-bedtime",
                 title: String(localized: "Won't last the night"),
                 body: String(localized: "\(BatteryEstimator.label(hours: runway.usableHours)) of recording left, but tonight needs about \(BatteryEstimator.label(hours: runway.requiredHours)). Charge before bed."),
                 interruptionLevel: .timeSensitive)
        }
    }

    private static func post(identifier: String, title: String, body: String,
                             interruptionLevel: UNNotificationInterruptionLevel = .active) {
        let center = UNUserNotificationCenter.current()
        // Authorization is requested once via requestAuthorization(); here only status is checked.
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // The escalation alerts request .timeSensitive to break through a sleep Focus; without the entitlement
            // the OS treats it as .active, so requesting is safe.
            content.interruptionLevel = interruptionLevel
            center.add(UNNotificationRequest(identifier: identifier,
                                             content: content, trigger: nil))
        }
    }
}
