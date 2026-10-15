import Foundation
import UserNotifications

/// Foreground presentation delegate for local notifications (wind-down, smart-alarm backup,
/// battery/illness alerts). Without it the OS suppresses banners while the app is in the foreground,
/// so a reminder tested with the app open would look broken. Register once at launch:
/// `UNUserNotificationCenter.current().delegate = NotificationPresenter.shared`.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationPresenter()

    private override init() { super.init() }

    /// Wired by the app root at launch to route a tapped morning-brief notification to Coach
    /// (`NavRouter.openCoach()`); nil is a safe no-op.
    var onCoachBriefTapped: (() -> Void)?

    /// Wired by the iOS root to open the screen a tapped notification is about.
    var onTargetTapped: ((NotificationTarget) -> Void)?

    /// Where a tapped notification leads, from its request identifier; nil leaves the app where it was.
    static func target(forIdentifier id: String) -> NotificationTarget? {
        switch true {
        case id.hasPrefix("smart-alarm-wake"): return .route(.alarms)
        case id.hasPrefix("wind-down-nudge"): return .route(.sleepPlanner)
        case id == "strain-target": return .route(.metric(HeroRingMetric.effort))
        case id == "illness-watch": return .route(.health)
        case id == "good-morning": return .route(.metric(HeroRingMetric.charge))
        case id.hasPrefix("battery-"): return .route(.dataSources)
        // The detected workout opens its Save / Not a workout sheet on Home; the move reminder opens Home.
        case id == "auto-workout": return .autoWorkout
        case id == "inactivity-nudge": return .home
        case id.hasPrefix("fasting-goal"): return .route(.fasting)
        default: return nil
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Handles a tap: the morning brief opens Coach, other known notifications open their screen.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.categoryIdentifier == CoachBriefScheduler.notificationCategoryId {
            onCoachBriefTapped?()
        } else if let target = Self.target(forIdentifier: response.notification.request.identifier) {
            onTargetTapped?(target)
        }
        completionHandler()
    }
}

/// What a tapped notification opens: Home, the detected-workout sheet, or a screen on the Home stack.
enum NotificationTarget: Equatable {
    case home
    case autoWorkout
    case route(TabRoute)
}
