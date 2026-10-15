import Foundation
import WhoopProtocol

// SedentaryDetector.swift — pure core of the inactivity reminder (wrist buzz after sitting too long).
//
// Sedentary time is inferred from gravity, not steps: the WHOOP 4.0 exposes no step count over BLE,
// only wrist accelerometer data via the ~15-min historical offload. The wrist moves constantly at a
// desk, so stillness is the wrong signal; the reminder needs the ABSENCE OF AMBULATION. The per-record
// gravity delta (WorkoutDetector.activitySeries) is smoothed over `smoothWindowS`; any stretch at/under
// `moveThresholdG` is a sedentary bout. Defaults come from on-wrist data (desk ≈ 0.05–0.10 g smoothed,
// walking ≈ 0.2–0.4 g).
//
// Pure: no I/O, no clock. `nowSec` and `tzOffsetSec` (seconds east of UTC) are passed in. Active/quiet
// hours are checked against the bout's LOCAL END TIME, not `now`: gravity only arrives on the offload
// flush, so an overnight bout is processed in the morning and a `now` check would wrongly admit it.
// All timestamps are wall-clock unix seconds. Outputs are approximate, not medical advice.

// MARK: - Output shapes

/// A sedentary period. Times are wall-clock unix seconds. Approximate.
public struct InactivityPeriod: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let durationS: Double
    public init(start: Int, end: Int, durationS: Double) {
        self.start = start; self.end = end; self.durationS = durationS
    }
}

/// The persisted de-dup / freshness state carried between offloads. The caller stores it verbatim
/// and feeds it back into the next `evaluate`; a fresh user starts from `.initial`.
public struct SedentaryState: Equatable, Sendable {
    /// Newest gravity ts already processed — a replayed / no-new-rows offload can't re-buzz.
    public var lastProcessedGravityTs: Int
    /// Unix-seconds of the last buzz (0 = never) — drives the re-nudge cadence.
    public var lastBuzzAt: Int
    /// Start of the last buzzed bout (0 = none) — distinguishes "same bout, re-nudge" from "new bout".
    public var lastBuzzedBoutStart: Int
    /// End of the last buzzed bout (0 = none).
    public var lastBuzzedBoutEnd: Int

    public init(lastProcessedGravityTs: Int = 0, lastBuzzAt: Int = 0,
                lastBuzzedBoutStart: Int = 0, lastBuzzedBoutEnd: Int = 0) {
        self.lastProcessedGravityTs = lastProcessedGravityTs
        self.lastBuzzAt = lastBuzzAt
        self.lastBuzzedBoutStart = lastBuzzedBoutStart
        self.lastBuzzedBoutEnd = lastBuzzedBoutEnd
    }

    /// A cold-start state (never processed, never buzzed).
    public static let initial = SedentaryState()
}

/// The engine's per-offload decision: whether to buzz, the strength, the triggering bout, and the
/// next state to persist.
public struct SedentaryDecision: Equatable, Sendable {
    /// True if the wrist should buzz on this offload.
    public let shouldBuzz: Bool
    /// How many buzz loops to play (strength) when `shouldBuzz` — mirrors `config.buzzLoops`.
    public let buzzLoops: Int
    /// The current sedentary bout that drove the decision, or nil if none qualified.
    public let bout: InactivityPeriod?
    /// The state to persist for the next offload (always advance `lastProcessedGravityTs`).
    public let nextState: SedentaryState

    public init(shouldBuzz: Bool, buzzLoops: Int, bout: InactivityPeriod?, nextState: SedentaryState) {
        self.shouldBuzz = shouldBuzz; self.buzzLoops = buzzLoops
        self.bout = bout; self.nextState = nextState
    }
}

/// User-tunable config for the inactivity reminder, including the global gates (master / quiet
/// hours / only-when-worn) passed in as plain values so the engine stays pure.
public struct SedentaryConfig: Equatable, Sendable {
    /// Inactivity reminder feature toggle (default off).
    public var enabled: Bool
    /// Global notification master switch (default off). Buzz is inert if off.
    public var notificationsMasterOn: Bool

    /// Smoothed wrist-motion above this (g) counts as walking, ending a sedentary bout.
    public var moveThresholdG: Double
    /// Minimum sedentary-bout length (minutes) before the first nudge.
    public var thresholdMinutes: Int
    /// Rolling-mean window (seconds) for the movement signal.
    public var smoothWindowSeconds: Double

    /// If still seated, re-buzz this often (minutes).
    public var reNudgeMinutes: Int
    /// Buzz strength (loops).
    public var buzzLoops: Int

    /// Only nudge during the active-hours window (default on).
    public var activeHoursEnabled: Bool
    /// Active-hours window start, local minute-of-day [0,1440) (default 9:00 = 540).
    public var activeStartMinutes: Int
    /// Active-hours window end, local minute-of-day [0,1440) (default 17:00 = 1020).
    public var activeEndMinutes: Int

    /// Suppress during quiet hours (default off).
    public var quietHoursEnabled: Bool
    /// Quiet-hours start, local minute-of-day (default 22:00 = 1320).
    public var quietStartMinutes: Int
    /// Quiet-hours end, local minute-of-day (default 7:00 = 420).
    public var quietEndMinutes: Int

    /// Require the strap to be worn (default on).
    public var onlyWhenWorn: Bool

    public init(enabled: Bool = false,
                notificationsMasterOn: Bool = false,
                moveThresholdG: Double = SedentaryDetector.defaultMoveThresholdG,
                thresholdMinutes: Int = SedentaryDetector.defaultThresholdMinutes,
                smoothWindowSeconds: Double = SedentaryDetector.defaultSmoothWindowS,
                reNudgeMinutes: Int = SedentaryDetector.defaultReNudgeMinutes,
                buzzLoops: Int = SedentaryDetector.defaultBuzzLoops,
                activeHoursEnabled: Bool = true,
                activeStartMinutes: Int = SedentaryDetector.defaultActiveStartMin,
                activeEndMinutes: Int = SedentaryDetector.defaultActiveEndMin,
                quietHoursEnabled: Bool = false,
                quietStartMinutes: Int = SedentaryDetector.defaultQuietStartMin,
                quietEndMinutes: Int = SedentaryDetector.defaultQuietEndMin,
                onlyWhenWorn: Bool = true) {
        self.enabled = enabled
        self.notificationsMasterOn = notificationsMasterOn
        self.moveThresholdG = moveThresholdG
        self.thresholdMinutes = thresholdMinutes
        self.smoothWindowSeconds = smoothWindowSeconds
        self.reNudgeMinutes = reNudgeMinutes
        self.buzzLoops = buzzLoops
        self.activeHoursEnabled = activeHoursEnabled
        self.activeStartMinutes = activeStartMinutes
        self.activeEndMinutes = activeEndMinutes
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStartMinutes = quietStartMinutes
        self.quietEndMinutes = quietEndMinutes
        self.onlyWhenWorn = onlyWhenWorn
    }
}

// MARK: - Engine

public enum SedentaryDetector {

    // MARK: Detector defaults

    /// Smoothed wrist-motion above this (g) counts as walking, ending a sedentary bout.
    public static let defaultMoveThresholdG: Double = 0.15
    /// Rolling-mean window (seconds): long enough that typing flurries average out, short enough that
    /// sustained walking crosses the threshold within a minute or two.
    public static let defaultSmoothWindowS: Double = 240.0
    /// Break a bout when the inter-record gap exceeds this (seconds); also the freshness tolerance for
    /// a bout still being "current".
    public static let maxGapS: Int = 20 * 60
    /// Default minimum sedentary-bout length (minutes).
    public static let defaultThresholdMinutes: Int = 45
    /// The detector's floor when a caller passes no user threshold.
    public static let defaultMinMinutes: Int = 15

    // MARK: Config defaults

    public static let defaultReNudgeMinutes: Int = 30
    public static let defaultBuzzLoops: Int = 2
    public static let defaultActiveStartMin: Int = 9 * 60   // 09:00
    public static let defaultActiveEndMin: Int = 17 * 60    // 17:00
    public static let defaultQuietStartMin: Int = 22 * 60   // 22:00
    public static let defaultQuietEndMin: Int = 7 * 60      // 07:00

    // MARK: - Detection

    /// Detect sedentary bouts: stretches where smoothed wrist-motion stays at/under `moveThresholdG`
    /// for ≥ `minMinutes`. Sustained walking or a data gap > `maxGapS` ends a bout.
    public static func detectSedentaryBouts(_ gravity: [GravitySample],
                                            moveThresholdG: Double = defaultMoveThresholdG,
                                            minMinutes: Int = defaultMinMinutes,
                                            smoothWindowSeconds: Double = defaultSmoothWindowS) -> [InactivityPeriod] {
        let rows = gravity.sorted { $0.ts < $1.ts }
        if rows.count < 2 { return [] }
        let motion = WorkoutDetector.activitySeries(rows)
        let smoothed = WorkoutDetector.smoothedIntensity(motion, windowS: smoothWindowSeconds)
        let ts = motion.map { $0.ts }
        let n = ts.count
        let minS = minMinutes * 60

        var out: [InactivityPeriod] = []
        var runStart = -1
        func closeRun(_ endIdx: Int) {
            if runStart >= 0 && runStart <= endIdx {
                let s = ts[runStart]
                let e = ts[endIdx]
                if e - s >= minS { out.append(InactivityPeriod(start: s, end: e, durationS: Double(e - s))) }
            }
            runStart = -1
        }
        for i in 0..<n {
            if i > 0 && ts[i] - ts[i - 1] > maxGapS { closeRun(i - 1) } // data gap ends the run
            if smoothed[i] > moveThresholdG {
                closeRun(i - 1) // walking-level motion ends the sedentary run
            } else if runStart < 0 {
                runStart = i
            }
        }
        closeRun(n - 1)
        return out
    }

    // MARK: - Pure time helpers

    /// Local minute-of-day [0,1440) for a unix-seconds instant given a tz offset (seconds east of UTC).
    public static func localMinuteOfDay(_ epochSec: Int, tzOffsetSec: Int) -> Int {
        let mod = ((epochSec + tzOffsetSec) % 86_400 + 86_400) % 86_400
        return mod / 60
    }

    /// Wrap-aware membership: is `minuteOfDay` inside `[startMin, endMin)` (window may cross midnight)?
    public static func windowContains(_ minuteOfDay: Int, startMin: Int, endMin: Int) -> Bool {
        if startMin <= endMin { return minuteOfDay >= startMin && minuteOfDay < endMin }
        return minuteOfDay >= startMin || minuteOfDay < endMin
    }

    /// The global + active/quiet-hours gate, evaluated against the bout's LOCAL END TIME. True only when
    /// the reminder may buzz for a bout ending at `boutEndEpochSec`.
    public static func mayBuzz(_ config: SedentaryConfig, worn: Bool, boutEndEpochSec: Int, tzOffsetSec: Int) -> Bool {
        if !config.enabled { return false }
        if !config.notificationsMasterOn { return false }
        if config.quietHoursEnabled {
            let mod = localMinuteOfDay(boutEndEpochSec, tzOffsetSec: tzOffsetSec)
            if windowContains(mod, startMin: config.quietStartMinutes, endMin: config.quietEndMinutes) { return false }
        }
        if config.onlyWhenWorn && !worn { return false }
        if config.activeHoursEnabled {
            let mod = localMinuteOfDay(boutEndEpochSec, tzOffsetSec: tzOffsetSec)
            if !windowContains(mod, startMin: config.activeStartMinutes, endMin: config.activeEndMinutes) { return false }
        }
        return true
    }

    // MARK: - The decision

    /// Run the reminder over the freshly-arrived `gravity` window and decide whether to buzz. Pure: pass
    /// `nowSec` (the offload-completion instant) and `tzOffsetSec` in.
    ///
    /// Order: disabled never buzzes; an offload that didn't advance the newest gravity ts is a no-op; the
    /// most-recent qualifying bout must still be current (end within `maxGapS` of the newest sample) and
    /// pass `mayBuzz`; a continuing bout re-nudges on cadence, a distinct new bout alerts on its own.
    public static func evaluate(_ gravity: [GravitySample],
                                state: SedentaryState,
                                config: SedentaryConfig,
                                worn: Bool,
                                nowSec: Int,
                                tzOffsetSec: Int) -> SedentaryDecision {
        func noBuzz(_ next: SedentaryState, _ bout: InactivityPeriod? = nil) -> SedentaryDecision {
            SedentaryDecision(shouldBuzz: false, buzzLoops: config.buzzLoops, bout: bout, nextState: next)
        }

        if !config.enabled { return noBuzz(state) }

        let newestGravityTs = gravity.map { $0.ts }.max()
        guard let newest = newestGravityTs else { return noBuzz(state) }

        // A replayed / no-new-rows sync can't fire.
        if newest <= state.lastProcessedGravityTs { return noBuzz(state) }
        var next = state
        next.lastProcessedGravityTs = newest

        let bouts = detectSedentaryBouts(gravity, moveThresholdG: config.moveThresholdG,
                                         minMinutes: config.thresholdMinutes,
                                         smoothWindowSeconds: config.smoothWindowSeconds)
        guard let bout = bouts.max(by: { $0.end < $1.end }) else { return noBuzz(next) }

        // The bout must be current (the user is still seated).
        if newest - bout.end > maxGapS { return noBuzz(next, bout) }
        if !mayBuzz(config, worn: worn, boutEndEpochSec: bout.end, tzOffsetSec: tzOffsetSec) { return noBuzz(next, bout) }

        let reNudgeS = config.reNudgeMinutes * 60
        // Continuing bout → re-nudge on cadence; a new bout (starts after the last buzzed one's end) alerts at once.
        let continues = bout.start <= state.lastBuzzedBoutEnd
        let shouldBuzz = state.lastBuzzAt == 0 || !continues || (nowSec - state.lastBuzzAt >= reNudgeS)
        if !shouldBuzz { return noBuzz(next, bout) }

        next.lastBuzzAt = nowSec
        next.lastBuzzedBoutStart = bout.start
        next.lastBuzzedBoutEnd = bout.end
        return SedentaryDecision(shouldBuzz: true, buzzLoops: config.buzzLoops, bout: bout, nextState: next)
    }
}
