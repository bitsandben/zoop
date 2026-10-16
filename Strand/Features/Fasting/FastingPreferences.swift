#if os(iOS)
import Foundation
import StrandAnalytics

/// The fasting plan, schedule and reminder settings (`zoop.fasting.*`). Device-local, not in `.zoopbak`.
enum FastingPreferences {
    private static let planKey = "zoop.fasting.planId"
    private static let customHoursKey = "zoop.fasting.customHours"
    private static let fixedKey = "zoop.fasting.fixedStart"
    private static let startMinuteKey = "zoop.fasting.startMinute"
    private static let autoStartKey = "zoop.fasting.autoStart"
    private static let lastAutoStartKey = "zoop.fasting.lastAutoStartTs"
    private static let showOnTodayKey = "zoop.fasting.showOnToday"
    private static let goalReminderKey = "zoop.fasting.goalReminder"
    private static let closingReminderKey = "zoop.fasting.closingReminder"
    private static let startReminderKey = "zoop.fasting.startReminder"

    private static var d: UserDefaults { .standard }

    static let defaultStartMinute = 20 * 60

    static var plan: FastingPlan {
        let hours = d.object(forKey: customHoursKey) as? Int ?? Int(FastingPlan.defaultPlan.fastingHours)
        return FastingPlan.resolve(id: d.string(forKey: planKey) ?? FastingPlan.defaultPlan.id, customHours: hours)
    }

    static func setPlan(_ plan: FastingPlan) {
        d.set(plan.id, forKey: planKey)
        if plan.isCustom { d.set(Int(plan.fastingHours), forKey: customHoursKey) }
    }

    /// Fixed daily start (e.g. 20:00) vs. flexible (the window counts from the end of each fast).
    static var usesFixedStart: Bool {
        get { d.bool(forKey: fixedKey) }
        set { d.set(newValue, forKey: fixedKey) }
    }

    /// Minutes after local midnight.
    static var startMinute: Int {
        get { d.object(forKey: startMinuteKey) as? Int ?? defaultStartMinute }
        set { d.set(((newValue % 1440) + 1440) % 1440, forKey: startMinuteKey) }
    }

    static var schedule: FastingSchedule {
        FastingSchedule(plan: plan, mode: usesFixedStart ? .fixed(startMinute: startMinute) : .flexible)
    }

    /// When the eating window closes: start the next fast from the planned time (true) or only remind.
    static var autoStart: Bool {
        get { d.bool(forKey: autoStartKey) }
        set { d.set(newValue, forKey: autoStartKey) }
    }

    /// The planned start an automatic fast last used, so it fires once per window.
    static var lastAutoStart: Date? {
        get { (d.object(forKey: lastAutoStartKey) as? Double).map { Date(timeIntervalSince1970: $0) } }
        set { d.set(newValue?.timeIntervalSince1970, forKey: lastAutoStartKey) }
    }

    /// Whether Today shows the fasting card. Off until the user starts a first fast or turns it on.
    static var showOnToday: Bool {
        get { d.bool(forKey: showOnTodayKey) }
        set { d.set(newValue, forKey: showOnTodayKey) }
    }

    /// The three opt-in notifications.
    enum Reminder: CaseIterable {
        case goal, closing, start

        fileprivate var key: String {
            switch self {
            case .goal: return goalReminderKey
            case .closing: return closingReminderKey
            case .start: return startReminderKey
            }
        }
    }

    static func isOn(_ reminder: Reminder) -> Bool { d.bool(forKey: reminder.key) }
    static func set(_ reminder: Reminder, _ on: Bool) { d.set(on, forKey: reminder.key) }
}
#endif
