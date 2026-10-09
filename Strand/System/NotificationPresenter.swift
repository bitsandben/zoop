import Foundation
import UserNotifications

/// Foreground presentation delegate for the app's local notifications (wind-down nudge, smart-alarm
/// backup, battery/illness alerts).
///
/// Without a `UNUserNotificationCenterDelegate`, iOS/macOS suppress a notification's banner while the
/// app is in the FOREGROUND (the default). A user testing a reminder with the app open would see
/// nothing and conclude notifications are broken. Returning banner + sound + list here makes them
/// visible whether the app is open or not — matching what the user expects from a reminder.
///
/// Cross-platform (iOS + macOS). Register once at launch:
/// `UNUserNotificationCenter.current().delegate = NotificationPresenter.shared`.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationPresenter()

    private override init() { super.init() }

    /// K5: wired by the app root (`StrandApp` on macOS, `StrandiOSApp` on iOS) at launch to route a
    /// tapped scheduled morning-brief notification to the Coach screen via `NavRouter.openCoach()`. nil
    /// is a safe no-op (the tap is simply not routed) rather than a crash if this ever fires before the
    /// root has wired it.
    var onCoachBriefTapped: (() -> Void)?

    /// Zoop: wired by the iOS root to open the screen a tapped notification is about. Before this every
    /// notification except the morning brief only brought the app forward wherever it was, which read
    /// as "nothing happens".
    var onTargetTapped: ((NotificationTarget) -> Void)?

    /// Where a tapped notification leads, decided from its request identifier (each poster uses a fixed
    /// identifier or prefix). nil leaves the app where it was.
    static func target(forIdentifier id: String) -> NotificationTarget? {
        switch true {
        case id.hasPrefix("smart-alarm-wake"): return .route(.alarms)
        case id.hasPrefix("wind-down-nudge"): return .route(.sleepPlanner)
        case id == "strain-target": return .route(.metric(HeroRingMetric.effort))
        case id == "illness-watch": return .route(.health)
        case id == "good-morning": return .route(.metric(HeroRingMetric.charge))
        case id.hasPrefix("battery-"): return .route(.dataSources)
        // The detected-workout card (Save / Not a workout) and the move reminder both live on Home.
        case id == "auto-workout", id == "inactivity-nudge": return .home
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

    /// Handle a tap on a delivered notification: the scheduled morning brief (K5) opens Coach, and every
    /// other known notification opens its screen through `onTargetTapped`.
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

/// What a tapped notification opens: Home itself, or a screen pushed on the Home stack.
enum NotificationTarget: Equatable {
    case home
    case route(TabRoute)
}
