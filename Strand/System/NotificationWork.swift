import Foundation
import UserNotifications

/// The one door to `UNUserNotificationCenter` for scheduling, cancelling and posting.
///
/// Every call runs on a private serial queue, never on the main thread: the first touch of the centre in a
/// process opens the usernotifications XPC connection, and that first touch was reached synchronously from
/// `AppModel.applySmartAlarm()` on the launch path, before notification authorization was known (a launch
/// freeze was reported on a fresh iOS 27 simulator). `withSettings` resolves the authorization status first and holds the queue until its body has
/// run, so a remove-then-add issued by one caller can never interleave with a later cancel from another.
/// Only the phone-side notification handling moves here; strap (BLE) commands are untouched.
enum NotificationWork {
    private static let queue = DispatchQueue(label: "com.zoopapp.zoop.notification-work", qos: .utility)

    /// Runs `body` on the notification queue, in submission order.
    static func run(_ body: @escaping @Sendable (UNUserNotificationCenter) -> Void) {
        queue.async { body(UNUserNotificationCenter.current()) }
    }

    /// Reads the notification settings off the main thread, then runs `body` with them. The queue is
    /// suspended until `body` returns, so work submitted afterwards observes its effects.
    static func withSettings(_ body: @escaping @Sendable (UNUserNotificationCenter, UNNotificationSettings) -> Void) {
        queue.async {
            let center = UNUserNotificationCenter.current()
            queue.suspend()
            center.getNotificationSettings { settings in
                body(center, settings)
                queue.resume()
            }
        }
    }
}
