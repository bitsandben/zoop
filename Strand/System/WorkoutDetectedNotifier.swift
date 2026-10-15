import Foundation
import UserNotifications
import StrandAnalytics

// MARK: - Detected-workout notification
//
// After each completed sync the auto-detect (`Repository.autoDetectCandidate`) runs and a new
// candidate posts one notification, so a workout found by a background sync isn't unseen until the
// next app open. Tapping opens the workout's sheet on Home (Save / "Not a workout"); the announced
// candidate is stored so Home shows exactly that workout until answered. Nothing is saved from here.

enum WorkoutDetectedNotifier {
    /// Start of the last candidate a notification was posted for, so each notifies once.
    private static let lastStartKey = "behavior.autoWorkoutNotifiedStart"

    /// Candidates whose starts lie closer than this are the same workout; the start edge drifts a few
    /// minutes as heart rate lands, so an exact match re-announced after nearly every sync.
    static let sameWorkoutToleranceSec = 30 * 60

    /// A candidate whose heart rate ended more recently than this may still be running; announcing it
    /// would store a truncated window, so it waits for a later sync.
    static let settleSec = 10 * 60

    /// Pure: whether a candidate has been over long enough to announce.
    static func isSettled(endSec: Int, now: Int) -> Bool {
        now - endSec >= settleSec
    }

    /// Pure: notify only for a candidate not already announced.
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

    /// Posts at most one notification per candidate. The marker is set before the async permission check
    /// (two syncs can't both post) and rolled back if notifications aren't allowed.
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
            // Home shows exactly this workout until saved or dismissed, whatever later scans find.
            d.set(Repository.encodePendingAutoWorkout(w), forKey: Repository.pendingAutoWorkoutKey)
        }
    }
}
