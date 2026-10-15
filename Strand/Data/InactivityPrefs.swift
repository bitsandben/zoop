import Foundation
import Combine
import StrandAnalytics

/// Settings and persisted de-dup state for the inactivity reminder (#419). UserDefaults-backed like
/// BehaviorStore; reuses the `notif.*` gate keys (written by NotificationSettingsStore) rather than forking
/// them.
/// Gating and de-dup live in `SedentaryDetector`; the BLE offload hook reads the engine seams straight from
/// UserDefaults.
/// Active hours are evaluated against the candidate bout's local END time, not `now`: gravity arrives on
/// the strap's offload flush, so an overnight bout is processed in the morning and must still be excluded.
@MainActor
final class InactivityPrefs: ObservableObject {

    /// Opt-in, default off. Inert until the notification master is also on.
    @Published var enabled: Bool        { didSet { d.set(enabled, forKey: K.enabled) } }
    /// Minutes seated before the first nudge (UI 15-120, step 15).
    @Published var thresholdMinutes: Int { didSet { d.set(thresholdMinutes, forKey: K.threshold) } }
    /// Re-buzz interval while still seated (UI 15-120, step 15).
    @Published var reNudgeMinutes: Int   { didSet { d.set(reNudgeMinutes, forKey: K.reNudge) } }
    /// Buzz strength in loops (UI 1-4).
    @Published var buzzLoops: Int        { didSet { d.set(buzzLoops, forKey: K.buzzLoops) } }
    /// Only nudge during active hours (default on).
    @Published var activeHoursEnabled: Bool { didSet { d.set(activeHoursEnabled, forKey: K.activeOn) } }
    /// Active-hours start, minutes since local midnight (default 09:00).
    @Published var activeStartMinutes: Int  { didSet { d.set(activeStartMinutes, forKey: K.activeStart) } }
    /// Active-hours end, minutes since local midnight (default 17:00).
    @Published var activeEndMinutes: Int    { didSet { d.set(activeEndMinutes, forKey: K.activeEnd) } }

    private let d = UserDefaults.standard
    private enum K {
        static let enabled     = "inactivity.enabled"
        static let threshold   = "inactivity.thresholdMinutes"
        static let reNudge     = "inactivity.reNudgeMinutes"
        static let buzzLoops   = "inactivity.buzzLoops"
        static let activeOn    = "inactivity.activeHoursEnabled"
        static let activeStart = "inactivity.activeStartMinutes"
        static let activeEnd   = "inactivity.activeEndMinutes"
        // Persisted so a relaunch cannot re-buzz a replayed window.
        static let lastProcessedTs = "inactivity.lastProcessedGravityTs"
        static let lastBuzzAt      = "inactivity.lastBuzzAt"
        static let lastBoutStart   = "inactivity.lastBuzzedBoutStart"
        static let lastBoutEnd     = "inactivity.lastBuzzedBoutEnd"
    }

    // Defaults match SedentaryDetector.
    init() {
        enabled            = d.object(forKey: K.enabled) as? Bool ?? false
        thresholdMinutes   = d.object(forKey: K.threshold) as? Int ?? SedentaryDetector.defaultThresholdMinutes  // 45
        reNudgeMinutes     = d.object(forKey: K.reNudge) as? Int ?? SedentaryDetector.defaultReNudgeMinutes      // 30
        buzzLoops          = d.object(forKey: K.buzzLoops) as? Int ?? SedentaryDetector.defaultBuzzLoops         // 2
        activeHoursEnabled = d.object(forKey: K.activeOn) as? Bool ?? true
        activeStartMinutes = d.object(forKey: K.activeStart) as? Int ?? SedentaryDetector.defaultActiveStartMin  // 09:00
        activeEndMinutes   = d.object(forKey: K.activeEnd) as? Int ?? SedentaryDetector.defaultActiveEndMin      // 17:00
    }

    // MARK: - Engine seams (UserDefaults-direct; safe to call off the UI store)
    //
    // These read/write the same keys as the @Published store so the BLE hook never touches a MainActor
    // ObservableObject.

    /// Notification settings keys reused for the global gates.
    private enum NotifK {
        static let master     = "notif.masterEnabled"
        static let worn       = "notif.onlyWhenWorn"
        static let quiet      = "notif.quietHoursEnabled"
        static let quietStart = "notif.quietStartMinutes"
        static let quietEnd   = "notif.quietEndMinutes"
    }

    /// Builds the engine's `SedentaryConfig` from the knobs and notification gates; detector tunables keep
    /// engine defaults.
    static func loadConfig(_ d: UserDefaults = .standard) -> SedentaryConfig {
        SedentaryConfig(
            enabled: d.object(forKey: K.enabled) as? Bool ?? false,
            notificationsMasterOn: d.object(forKey: NotifK.master) as? Bool ?? false,
            thresholdMinutes: d.object(forKey: K.threshold) as? Int ?? SedentaryDetector.defaultThresholdMinutes,
            reNudgeMinutes: d.object(forKey: K.reNudge) as? Int ?? SedentaryDetector.defaultReNudgeMinutes,
            buzzLoops: d.object(forKey: K.buzzLoops) as? Int ?? SedentaryDetector.defaultBuzzLoops,
            activeHoursEnabled: d.object(forKey: K.activeOn) as? Bool ?? true,
            activeStartMinutes: d.object(forKey: K.activeStart) as? Int ?? SedentaryDetector.defaultActiveStartMin,
            activeEndMinutes: d.object(forKey: K.activeEnd) as? Int ?? SedentaryDetector.defaultActiveEndMin,
            quietHoursEnabled: d.object(forKey: NotifK.quiet) as? Bool ?? false,
            quietStartMinutes: d.object(forKey: NotifK.quietStart) as? Int ?? SedentaryDetector.defaultQuietStartMin,
            quietEndMinutes: d.object(forKey: NotifK.quietEnd) as? Int ?? SedentaryDetector.defaultQuietEndMin,
            onlyWhenWorn: d.object(forKey: NotifK.worn) as? Bool ?? true
        )
    }

    /// Cheap pre-check so the hook can bail before any DB read.
    static func isEnabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: K.enabled) as? Bool ?? false
    }

    /// Rehydrates the persisted de-dup state fed back into `evaluate`.
    static func loadState(_ d: UserDefaults = .standard) -> SedentaryState {
        SedentaryState(
            lastProcessedGravityTs: d.object(forKey: K.lastProcessedTs) as? Int ?? 0,
            lastBuzzAt: d.object(forKey: K.lastBuzzAt) as? Int ?? 0,
            lastBuzzedBoutStart: d.object(forKey: K.lastBoutStart) as? Int ?? 0,
            lastBuzzedBoutEnd: d.object(forKey: K.lastBoutEnd) as? Int ?? 0
        )
    }

    /// Persists the engine's `nextState`.
    static func saveState(_ s: SedentaryState, to d: UserDefaults = .standard) {
        d.set(s.lastProcessedGravityTs, forKey: K.lastProcessedTs)
        d.set(s.lastBuzzAt, forKey: K.lastBuzzAt)
        d.set(s.lastBuzzedBoutStart, forKey: K.lastBoutStart)
        d.set(s.lastBuzzedBoutEnd, forKey: K.lastBoutEnd)
    }

    /// Local tz offset (seconds east of UTC) at `epochSec`; DST-correct for the bout's end time.
    static func tzOffsetSec(_ epochSec: Int) -> Int {
        TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(epochSec)))
    }
}
