import Foundation
import UserNotifications
import StrandAnalytics

// MARK: - Detected-workout notification
//
// The auto-detect suggestion used to surface only when Today was on screen, so a workout found by a
// background sync waited unseen until the next app open. After each completed sync the same detector
// runs (`Repository.autoDetectCandidate`), and a new candidate posts one notification. Tapping it opens
// the workout's sheet on Home, where Save and "Not a workout" live, and the announced candidate is stored
// so Home shows exactly that workout until it is answered. Nothing is saved from here: the
// suggestion-only promise in Settings still holds.

enum WorkoutDetectedNotifier {
    /// The start of the last candidate a notification was posted for, so each one notifies once.
    private static let lastStartKey = "behavior.autoWorkoutNotifiedStart"

    /// Two candidates whose starts lie closer than this are the same workout. The detector re-runs after
    /// every sync and its start edge moves by a few minutes as more heart rate lands, so an exact match
    /// re-announced one workout after nearly every sync.
    static let sameWorkoutToleranceSec = 30 * 60

    /// A candidate whose heart rate ended more recently than this may still be running: the detector
    /// only sees the data synced so far. Announcing it would store a truncated window as the workout
    /// Home offers to save, so it waits for a later sync.
    static let settleSec = 10 * 60

    /// Pure, testable: whether a candidate has been over long enough to announce.
    static func isSettled(endSec: Int, now: Int) -> Bool {
        now - endSec >= settleSec
    }

    /// Pure, testable decision: notify only for a candidate not already announced.
    static func shouldNotify(enabled: Bool, candidateStart: Int?, lastNotifiedStart: Int?) -> Bool {
        guard enabled, let candidateStart else { return false }
        guard let last = lastNotifiedStart else { return true }
        return abs(candidateStart - last) >= sameWorkoutToleranceSec
    }

    static func copy(for w: DetectedWorkout) -> (title: String, body: String) {
        let start = Date(timeIntervalSince1970: TimeInterval(w.startSec))
            .formatted(date: .omitted, time: .shortened)
        return (String(localized: "Workout detected"),
                String(localized: "\(w.durationMin) min from \(start), average \(w.avgBpm) bpm. Open Zoop to save it."))
    }

    /// Posts at most one notification per candidate. The marker is set before the asynchronous
    /// permission check, so two syncs landing together cannot both post, and rolled back when
    /// notifications are not allowed, so the candidate is still announced once they are.
    static func onSyncCompleted(candidate: DetectedWorkout?, enabled: Bool, now: Date = Date()) {
        let d = UserDefaults.standard
        let last = d.object(forKey: lastStartKey) as? Int
        guard shouldNotify(enabled: enabled, candidateStart: candidate?.startSec, lastNotifiedStart: last),
              let w = candidate, isSettled(endSec: w.endSec, now: Int(now.timeIntervalSince1970)) else { return }
        d.set(w.startSec, forKey: lastStartKey)
        let copy = copy(for: w)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let d = UserDefaults.standard
            guard settings.authorizationStatus == .authorized else {
                if d.object(forKey: lastStartKey) as? Int == w.startSec {
                    if let last { d.set(last, forKey: lastStartKey) } else { d.removeObject(forKey: lastStartKey) }
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "auto-workout", content: content, trigger: nil))
            // Home shows exactly this workout until it is saved or dismissed, whatever later scans find.
            d.set(Repository.encodePendingAutoWorkout(w), forKey: Repository.pendingAutoWorkoutKey)
        }
    }
}
