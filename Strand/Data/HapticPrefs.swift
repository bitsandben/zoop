import Foundation

/// Per-event toggles for in-session strap-haptic cues (#1115); keys and default-on must match Android
/// `HapticPrefs`.
/// These cues respond to something the user started (Breathing, Interval timer, Live Session, workout
/// start/end, biofeedback), so they default on (opt-out). Ambient cues (inactivity, stress, calls) keep
/// their own opt-in keys. Nonisolated so any actor can read a gate.
enum HapticPrefs {
    // `breathing` also covers resonance/biofeedback cues. Double-tap is not here; it is opt-in via DoubleTapAction.
    static let breathing = "haptics.breathing"
    static let intervals = "haptics.intervals"
    /// Lift Log rest-timer buzz, five seconds before rest ends. Separate from `intervals` since the phone
    /// may be face-down at the rack.
    static let liftRest = "haptics.liftRest"
    static let liveSession = "haptics.liveSession"
    static let workout = "haptics.workout"

    /// Whether an in-session cue may fire. Default on: `UserDefaults.bool` returns false for a missing key,
    /// so read the object and default to true (matches the `@AppStorage = true` bindings).
    static func enabled(_ key: String, _ d: UserDefaults = .standard) -> Bool {
        (d.object(forKey: key) as? Bool) ?? true
    }

    static func setEnabled(_ key: String, _ value: Bool, _ d: UserDefaults = .standard) {
        d.set(value, forKey: key)
    }
}
