import Foundation

// AutoWorkoutGate.swift — Zoop's stricter "is this really a workout?" gate for auto-detect suggestions.
//
// `AutoWorkoutDetector.detect` finds sustained raised heart rate (resting + 30 bpm for 12 minutes). That
// alone kept offering ordinary mornings as workouts: getting up, showering and walking around the house
// lift heart rate 30-40 bpm above a sleeping resting rate for half an hour. This gate runs on the
// detector's candidates and keeps only sessions that are clearly exercise:
//
//  1. Motion confirmation is mandatory. With no wrist-movement series there is no suggestion at all
//     (the detector's own motion mean check then decides whether the window moved enough).
//  2. At least `minDurationMin` minutes long.
//  3. Intensity relative to heart-rate reserve (Karvonen): the average must reach
//     resting + `minReserveFraction` x (HRmax - resting).
//  4. A window that overlaps a sleep, or starts within `postSleepWindowSec` after a sleep ends (the
//     night or a nap), must reach resting + `postSleepReserveFraction` x reserve instead.
//
// Pure / headless: no I/O, no clock. All timestamps are unix SECONDS. NOT medical advice.

public enum AutoWorkoutGate {

    /// Shortest suggestion, in whole minutes.
    public static let minDurationMin = 15
    /// Average heart rate must reach this share of heart-rate reserve above resting.
    public static let minReserveFraction = 0.40
    /// The stricter share used right after (or during) a sleep, where getting up looks like effort.
    public static let postSleepReserveFraction = 0.50
    /// How long after a sleep ends the stricter share applies (60 minutes).
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

    /// Whether one detector candidate is a workout worth suggesting.
    /// - Parameter motionConfirmed: the caller ran the detector WITH a motion series (so the window's
    ///   movement was checked). false means there was no movement data, and nothing is suggested.
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

    /// Run the published detector with the mandatory motion series, then this gate. nil or empty motion
    /// returns no candidates.
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
