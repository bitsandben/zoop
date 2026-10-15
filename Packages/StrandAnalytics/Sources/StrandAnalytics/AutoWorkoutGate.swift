import Foundation

// Zoop's stricter "is this really a workout?" gate for auto-detect suggestions. Sustained raised HR
// alone offered ordinary mornings (getting up, showering) as workouts. Keeps only candidates that:
// 1. have motion confirmation (no wrist-movement series means no suggestion at all);
// 2. last at least `minDurationMin` minutes;
// 3. average at least resting + `minReserveFraction` x (HRmax - resting) (Karvonen);
// 4. if overlapping a sleep or starting within `postSleepWindowSec` after one, reach resting +
//    `postSleepReserveFraction` x reserve instead.
// Pure: no I/O or clock; timestamps are unix seconds. Not medical advice.

public enum AutoWorkoutGate {

    /// Shortest suggestion, in whole minutes.
    public static let minDurationMin = 15
    /// Average heart rate must reach this share of heart-rate reserve above resting.
    public static let minReserveFraction = 0.40
    /// Stricter share used during or right after a sleep, where getting up looks like effort.
    public static let postSleepReserveFraction = 0.50
    /// How long after a sleep ends the stricter share applies.
    public static let postSleepWindowSec = 60 * 60
    /// HRmax when neither a profile value nor an age is known.
    public static let fallbackHRMax = 190.0

    /// One sleep (the night or a nap), [startSec, endSec].
    public struct SleepSpan: Equatable, Sendable {
        public let startSec: Int
        public let endSec: Int
        public init(startSec: Int, endSec: Int) {
            self.startSec = startSec
            self.endSec = endSec
        }
    }

    /// HRmax to judge intensity against: the profile's value when set, else 220 - age, else 190.
    public static func hrMax(profileHRMax: Double?, age: Int?) -> Double {
        if let p = profileHRMax, p > 0 { return p }
        if let age, age > 0, age < 120 { return Double(220 - age) }
        return fallbackHRMax
    }

    /// The average heart rate a window needs to count, given resting HR, HRmax and the reserve share.
    public static func requiredAvgBpm(restingBpm: Int?, hrMax: Double, reserveFraction: Double) -> Double {
        let rest = Double(restingBpm ?? AutoWorkoutDetector.defaultRestingHR)
        let reserve = max(0, hrMax - rest)
        return rest + reserveFraction * reserve
    }

    /// True when the window overlaps a sleep or starts within `postSleepWindowSec` after one ends.
    public static func isNearSleep(startSec: Int, endSec: Int, sleeps: [SleepSpan]) -> Bool {
        sleeps.contains { s in
            let overlaps = startSec <= s.endSec && s.startSec <= endSec
            let justAfter = startSec >= s.endSec && startSec - s.endSec < postSleepWindowSec
            return overlaps || justAfter
        }
    }

    /// Whether one detector candidate is worth suggesting.
    /// - Parameter motionConfirmed: the caller ran the detector with a motion series; false means no
    ///   movement data, and nothing is suggested.
    public static func passes(_ w: DetectedWorkout,
                              restingBpm: Int?,
                              hrMax: Double,
                              sleeps: [SleepSpan],
                              motionConfirmed: Bool) -> Bool {
        guard motionConfirmed else { return false }
        guard w.durationMin >= minDurationMin else { return false }
        let share = isNearSleep(startSec: w.startSec, endSec: w.endSec, sleeps: sleeps)
            ? postSleepReserveFraction : minReserveFraction
        return Double(w.avgBpm) >= requiredAvgBpm(restingBpm: restingBpm, hrMax: hrMax, reserveFraction: share)
    }

    /// Run the published detector with the mandatory motion series, then this gate; nil or empty motion returns no candidates.
    public static func detect(hr: [(ts: Int, bpm: Int)],
                              restingBpm: Int?,
                              hrMax: Double,
                              motion: [AutoWorkoutDetector.MotionPoint]?,
                              sleeps: [SleepSpan],
                              savedSpans: [SavedWorkoutSpan] = []) -> [DetectedWorkout] {
        guard let motion, !motion.isEmpty else { return [] }
        return AutoWorkoutDetector.detect(hr: hr, restingBpm: restingBpm, motion: motion,
                                          savedSpans: savedSpans)
            .filter { passes($0, restingBpm: restingBpm, hrMax: hrMax, sleeps: sleeps, motionConfirmed: true) }
    }
}
