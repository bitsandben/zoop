import Foundation
import UserNotifications

/// The wind-down nudge: a gentle, non-critical evening local notification suggesting the user start
/// winding down. A backgrounded sideloaded app can't fire a dependable loud alarm (no critical-alert
/// entitlement) but can post a calm daily reminder. Fires on a repeating calendar trigger at the
/// earliest wake time minus sleep need minus a short lead. Own UserDefaults-backed state; on-device only.
@MainActor
enum WindDownNudge {

    private static let requestId = "wind-down-nudge"

    // MARK: - Persisted settings (own keys; default OFF)

    private enum K {
        static let enabled = "windDown.enabled"
        static let sleepNeed = "windDown.sleepNeedMinutes"   // default 8h
        static let lead = "windDown.leadMinutes"             // default 30m
        static let wake = "windDown.wakeMinutes"             // earliest wake, minutes since midnight
        // Per-day wake overrides: JSON {weekday(1=Sun...7=Sat): wakeMinutes}. No entry for a day means the default `wakeMinutes`.
        static let perDayWake = "windDown.perDayWakeMinutes"
        // Follow tonight's computed sleep need (`SleepDebt.needTonight`) instead of the fixed setting; default on.
        static let followsNeed = "zoop.windDown.followsSleepNeed"
        static let tonightNeed = "zoop.windDown.tonightNeedMinutes"
    }

    /// Whether the reminder uses tonight's computed sleep need rather than the fixed setting.
    static var followsSleepNeed: Bool {
        UserDefaults.standard.object(forKey: K.followsNeed) as? Bool ?? true
    }

    static func setFollowsSleepNeed(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: K.followsNeed)
        if isEnabled { schedule() }
    }

    /// The last computed sleep need for tonight, in minutes, or nil before one was computed.
    static var tonightNeedMinutes: Int? {
        UserDefaults.standard.object(forKey: K.tonightNeed) as? Int
    }

    /// Record tonight's computed sleep need; reschedules when it moved by five minutes or more.
    static func updateTonightNeed(_ minutes: Int) {
        let clamped = min(max(minutes, 5 * 60), 11 * 60)
        if let old = tonightNeedMinutes, abs(old - clamped) < 5 { return }
        UserDefaults.standard.set(clamped, forKey: K.tonightNeed)
        if isEnabled && followsSleepNeed { schedule() }
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }

    static var sleepNeedMinutes: Int {
        if followsSleepNeed, let tonight = tonightNeedMinutes { return min(max(tonight, 5 * 60), 11 * 60) }
        let v = UserDefaults.standard.object(forKey: K.sleepNeed) as? Int ?? 8 * 60
        return min(max(v, 5 * 60), 11 * 60)
    }

    static var leadMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.lead) as? Int ?? 30
        return min(max(v, 0), 120)
    }

    /// Whether a wake time was ever set (otherwise `wakeMinutes` is the 07:00 default).
    static var hasWakeSetting: Bool { UserDefaults.standard.object(forKey: K.wake) != nil }

    static var wakeMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.wake) as? Int ?? 7 * 60   // 07:00
        return min(max(v, 0), 24 * 60 - 1)
    }

    // MARK: - Per-day wake overrides

    /// Stored per-weekday wake overrides ({weekday(1=Sun...7=Sat): wakeMinutes}), empty by default.
    /// Values are clamped to a valid minute-of-day on read so a corrupt blob can't schedule nonsense.
    static var perDayWakeOverrides: [Int: Int] {
        guard let data = UserDefaults.standard.data(forKey: K.perDayWake),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        var out: [Int: Int] = [:]
        for (k, v) in raw {
            guard let day = Int(k), (1...7).contains(day) else { continue }
            out[day] = min(max(v, 0), 24 * 60 - 1)
        }
        return out
    }

    /// The wake time for a Calendar weekday (1=Sun...7=Sat): the override if set, else `wakeMinutes`.
    /// The single source for both the schedule and the UI.
    static func wakeMinutes(forWeekday weekday: Int) -> Int {
        if let alarm = alarmWakeMinutes(forWeekday: weekday) { return alarm }
        return perDayWakeOverrides[weekday] ?? wakeMinutes
    }

    /// When following the sleep need and the strap alarm rings on `weekday`, the alarm is the wake time
    /// (the day's override, else the alarm's own time), read from `BehaviorStore` settings.
    static func alarmWakeMinutes(forWeekday weekday: Int) -> Int? {
        let d = UserDefaults.standard
        guard followsSleepNeed, d.bool(forKey: "behavior.smartAlarmEnabled") else { return nil }
        if let days = d.array(forKey: "behavior.smartAlarmWeekdays") as? [Int], !days.isEmpty,
           !days.contains(weekday) { return nil }
        let base = d.object(forKey: "behavior.smartAlarmMinutes") as? Int ?? 7 * 60
        return perDayWakeOverrides[weekday] ?? base
    }

    /// Reschedules with the current settings, if the reminder is on.
    static func refresh() {
        if isEnabled { schedule() }
    }

    /// Whether any per-day override is set: fans scheduling out to 7 weekday triggers instead of one daily trigger.
    static var hasPerDayOverrides: Bool { !perDayWakeOverrides.isEmpty }

    /// Sets or clears (nil) a weekday's wake override, rescheduling if enabled; clamps the minute-of-day.
    static func setWakeOverride(weekday: Int, minutes: Int?) {
        guard (1...7).contains(weekday) else { return }
        var map = perDayWakeOverrides
        if let m = minutes {
            map[weekday] = min(max(m, 0), 24 * 60 - 1)
        } else {
            map.removeValue(forKey: weekday)
        }
        let encodable = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: K.perDayWake)
        }
        if isEnabled { schedule() }
    }

    /// The nudge minute-of-day for a weekday: wake (override or default) minus sleep need minus lead,
    /// wrapped into [0, 1440). Pure.
    static func nudgeMinuteOfDay(forWeekday weekday: Int) -> Int {
        let raw = wakeMinutes(forWeekday: weekday) - sleepNeedMinutes - leadMinutes
        let day = 24 * 60
        return ((raw % day) + day) % day
    }

    /// The day shift for a weekday's nudge: 0 if it lands on the wake's day, -1 if it wraps to the
    /// previous evening. The minute-of-day wrap loses which day the nudge belongs to, so the scheduler
    /// uses this to pin the trigger to the nudge's day (#1863). With clamped inputs `raw` is in
    /// [-780, 1139], so the shift is 0 or -1; the formula is general floor division.
    static func nudgeDayShift(forWeekday weekday: Int) -> Int {
        let raw = wakeMinutes(forWeekday: weekday) - sleepNeedMinutes - leadMinutes
        let day = 24 * 60
        // Floor division (Swift's `/` truncates toward zero).
        return raw < 0 ? -(((-raw - 1) / day) + 1) : raw / day
    }

    /// Shifts a Calendar weekday (1=Sun...7=Sat) by a day count, wrapping the week: `(1, by: -1)` is 7.
    static func shiftedWeekday(weekday: Int, by shift: Int) -> Int {
        let zeroBased = weekday - 1 + shift
        return ((zeroBased % 7) + 7) % 7 + 1
    }

    // MARK: - Public API

    /// Result of enabling the nudge. `.denied` means the OS won't deliver, so the caller should revert
    /// the switch and point the user at Settings.
    enum EnableOutcome { case scheduled, denied, off }

    /// Enables/disables and (re)schedules. Enabling checks notification authorization first (asking once
    /// if undetermined, scheduling on grant); if denied it reports back rather than persisting a toggle
    /// the OS would never deliver. `completion` always runs on the main actor.
    static func setEnabled(_ on: Bool, completion: (@MainActor (EnableOutcome) -> Void)? = nil) {
        guard on else {
            UserDefaults.standard.set(false, forKey: K.enabled)
            // Clear the single trigger and any per-day triggers so disabling leaves nothing behind.
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [requestId] + perDayRequestIds)
            completion?(.off)
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    UserDefaults.standard.set(true, forKey: K.enabled)
                    schedule()
                    completion?(.scheduled)
                case .notDetermined:
                    // First ask: schedule on grant so the first night is covered.
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in
                            if granted {
                                UserDefaults.standard.set(true, forKey: K.enabled)
                                schedule()
                                completion?(.scheduled)
                            } else {
                                UserDefaults.standard.set(false, forKey: K.enabled)
                                completion?(.denied)
                            }
                        }
                    }
                default:
                    // .denied (or any future non-authorized case): don't fake an enabled toggle.
                    UserDefaults.standard.set(false, forKey: K.enabled)
                    completion?(.denied)
                }
            }
        }
    }

    /// Updates the earliest wake time the nudge derives from, rescheduling if enabled.
    static func setWakeMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 0), 24 * 60 - 1), forKey: K.wake)
        if isEnabled { schedule() }
    }

    /// The minute-of-day the nudge fires: wake - sleepNeed - lead, wrapped into [0, 1440).
    static func nudgeMinuteOfDay() -> Int {
        let raw = wakeMinutes - sleepNeedMinutes - leadMinutes
        let day = 24 * 60
        return ((raw % day) + day) % day
    }

    // MARK: - Scheduling

    /// Per-weekday request ids, cleared alongside the single id so toggling overrides never leaves a stale trigger.
    private static var perDayRequestIds: [String] { (1...7).map { "\(requestId)-wd\($0)" } }

    private static func schedule() {
        let center = UNUserNotificationCenter.current()
        // Clear both the single and per-day triggers so switching modes never double-fires or orphans a reminder.
        center.removePendingNotificationRequests(withIdentifiers: [requestId] + perDayRequestIds)

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time to wind down")
        if followsSleepNeed, let need = tonightNeedMinutes {
            content.body = String(localized: "You need about \(need / 60) h \(need % 60) min of sleep tonight. Winding down now gets you there.")
        } else {
            content.body = String(localized: "A calm hour now helps you hit your wake time well-rested.")
        }
        content.sound = .default

        // With per-day overrides, fan out to seven weekday-pinned triggers at each day's nudge time; with none, one daily trigger.
        if hasPerDayOverrides || (1...7).contains(where: { alarmWakeMinutes(forWeekday: $0) != nil }) {
            for weekday in 1...7 {
                let minute = nudgeMinuteOfDay(forWeekday: weekday)
                // An early wake (e.g. 03:30) wraps the nudge to the previous evening; pin the trigger to the
                // nudge's day, not the wake's (#1863).
                let shift = nudgeDayShift(forWeekday: weekday)
                var comps = DateComponents()
                comps.weekday = shiftedWeekday(weekday: weekday, by: shift)   // the nudge's day
                comps.hour = minute / 60
                comps.minute = minute % 60
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                // The request id stays keyed to the wake's weekday to match `perDayRequestIds`.
                center.add(UNNotificationRequest(identifier: "\(requestId)-wd\(weekday)",
                                                 content: content, trigger: trigger))
            }
            return
        }

        let minute = nudgeMinuteOfDay()
        var comps = DateComponents()
        comps.hour = minute / 60
        comps.minute = minute % 60
        // repeats: true is a daily calendar trigger that lives in the notification center and survives relaunch.
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: requestId, content: content, trigger: trigger))
    }
}
