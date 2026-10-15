import Foundation

// HRDownPacer.swift - the L2 "buzz-below-heart-rate" relaxation metronome. Gives the heart a felt
// rhythm a few bpm BELOW its current rate; HR tends to drift toward an external rhythmic cue
// (ISWC 2025). Pure and unit-tested; the live controller reads smoothed HR off `AppModel.bpm`,
// calls `next(...)`, fires one light buzz per returned interval, and re-asks every recompute window.
//
// Safety envelope (a relaxation metronome, not cardiac control; bounded, never therapeutic):
//   - Target tempo T = smoothedHR - delta, where delta ramps from `startDeltaBpm` to `maxDeltaBpm`
//     so the cue trails the heart down rather than yanking it.
//   - T never drops below `hrFloorBpm` and never more than `maxDeltaBpm` below live HR.
//   - T is recomputed every `recomputeSeconds` from the new smoothed HR, so it follows HR down.
//   - Auto-stops when HR settles near a calm target, on timeout, or on user stop.
//   - If HR didn't fall, the caller says so plainly; never a fabricated success.
// We never claim it "lowers your heart rate" as a therapeutic outcome.

public enum HRDownPacer {

    // MARK: - Config

    /// The L2 safety and behaviour envelope. Defaults are conservative; all bpm values are beats/min,
    /// durations seconds.
    public struct Config: Equatable, Sendable {
        /// Initial delta below live HR at session start (gentle).
        public var startDeltaBpm: Double
        /// Maximum delta below live HR (a felt cue, never a shock).
        public var maxDeltaBpm: Double
        public var deltaRampSeconds: Double
        public var hrFloorBpm: Double
        public var recomputeSeconds: Double
        public var calmTargetBpm: Double
        public var maxDurationSeconds: Double

        public init(startDeltaBpm: Double = 3.0,
                    maxDeltaBpm: Double = 8.0,
                    deltaRampSeconds: Double = 120.0,
                    hrFloorBpm: Double = 50.0,
                    recomputeSeconds: Double = 15.0,
                    calmTargetBpm: Double = 60.0,
                    maxDurationSeconds: Double = 180.0) {
            self.startDeltaBpm = startDeltaBpm
            self.maxDeltaBpm = maxDeltaBpm
            self.deltaRampSeconds = deltaRampSeconds
            self.hrFloorBpm = hrFloorBpm
            self.recomputeSeconds = recomputeSeconds
            self.calmTargetBpm = calmTargetBpm
            self.maxDurationSeconds = maxDurationSeconds
        }

        public static let `default` = Config()
    }

    // MARK: - Step output

    /// The next step: fire a pulse at `intervalMs` (one light buzz per target beat), or `stop` with a
    /// reason (then `intervalMs` is nil). `targetBpm` is the tempo chosen this step, for the live UI.
    public struct Step: Equatable, Sendable {
        /// Inter-pulse interval in ms (60000 / targetBpm), or nil when stopping.
        public let intervalMs: Int?
        public let stop: Bool
        public let targetBpm: Double?
        /// Why we stopped (nil while running), for an honest outcome line.
        public let stopReason: StopReason?

        public init(intervalMs: Int?, stop: Bool, targetBpm: Double?, stopReason: StopReason?) {
            self.intervalMs = intervalMs; self.stop = stop
            self.targetBpm = targetBpm; self.stopReason = stopReason
        }
    }

    /// Why an L2 session ended; drives the outcome copy.
    public enum StopReason: String, Equatable, Sendable {
        case settled
        case timeout
        /// Live HR was implausible or out of the resting band (the caller should gate before starting).
        case invalidHR
    }

    // MARK: - Controller

    /// Computes the next metronome step from the current smoothed HR (the caller smooths) and elapsed
    /// session time (drives the delta ramp and timeout).
    ///
    /// While running, the pulse tempo is `currentHR - delta(elapsed)`, bounded below by `hrFloorBpm` and
    /// by `currentHR - maxDeltaBpm`. Monotone: a non-increasing HR trajectory yields non-increasing
    /// target tempos, so the cue only ever trails down.
    public static func next(currentHR: Double, elapsed: Double, config: Config = .default) -> Step {
        // Implausible HR: last-ditch guard (the caller gates on the resting band).
        guard currentHR.isFinite, currentHR > 0 else {
            return Step(intervalMs: nil, stop: true, targetBpm: nil, stopReason: .invalidHR)
        }
        if elapsed >= config.maxDurationSeconds {
            return Step(intervalMs: nil, stop: true, targetBpm: nil, stopReason: .timeout)
        }
        if currentHR <= config.calmTargetBpm {
            return Step(intervalMs: nil, stop: true, targetBpm: nil, stopReason: .settled)
        }

        // Delta ramps linearly start to max over `deltaRampSeconds`, then holds.
        let delta = rampedDelta(elapsed: elapsed, config: config)

        // Never below the floor or the calm target, and never paced above HR.
        var target = currentHR - delta
        if target < config.hrFloorBpm { target = config.hrFloorBpm }
        if target > currentHR { target = currentHR }   // defensive: never pace at/above live HR
        // Keep the cue at least 1 bpm under the heart so it stays a "below-HR" metronome.
        if target > currentHR - 1.0 { target = max(config.hrFloorBpm, currentHR - 1.0) }

        let intervalMs = Int((60_000.0 / target).rounded())
        return Step(intervalMs: intervalMs, stop: false, targetBpm: target, stopReason: nil)
    }

    /// The delta-below-HR at a given elapsed time: linear ramp over `deltaRampSeconds`, clamped to
    /// `maxDeltaBpm` after.
    public static func rampedDelta(elapsed: Double, config: Config = .default) -> Double {
        guard config.deltaRampSeconds > 0 else { return config.maxDeltaBpm }
        let t = min(max(elapsed, 0), config.deltaRampSeconds) / config.deltaRampSeconds
        return config.startDeltaBpm + (config.maxDeltaBpm - config.startDeltaBpm) * t
    }
}
