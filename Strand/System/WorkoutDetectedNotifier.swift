import Foundation
import UserNotifications
import StrandAnalytics

// MARK: - Detected-workout notification
//
// The auto-detect suggestion used to surface only when Today was on screen, so a workout found by a
// background sync waited unseen until the next app open. After each completed sync the same detector
// runs (`Repository.autoDetectCandidate`), and a new candidate posts one notification pointing at the
// Home card, where Save and "Not a workout" live. Nothing is saved from here: the suggestion-only
// promise in Settings still holds.

enum WorkoutDetectedNotifier {
    /// The start of the last candidate a notification was posted for, so each one notifies once.
    private static let lastStartKey = "behavior.autoWorkoutNotifiedStart"

    /// Two candidates whose starts lie closer than this are the same workout. The detector re-runs after
    /// every sync and its start edge moves by a few minutes as more heart rate lands, so an exact match
    /// re-announced one workout after nearly every sync.
    static let sameWorkoutToleranceSec = 30 * 60

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

    /// Posts at most one notification per candidate. The marker advances only after an authorized post,
    /// so a candidate found while notifications are off is still announced once they are allowed.
    static func onSyncCompleted(candidate: DetectedWorkout?, enabled: Bool) {
        let d = UserDefaults.standard
        let last = d.object(forKey: lastStartKey) as? Int
        guard shouldNotify(enabled: enabled, candidateStart: candidate?.startSec, lastNotifiedStart: last),
              let w = candidate else { return }
        let copy = copy(for: w)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "auto-workout", content: content, trigger: nil))
            UserDefaults.standard.set(w.startSec, forKey: lastStartKey)
        }
    }
}
