import Foundation

// StressOnsetDetector: the closed-loop JITAI detector that decides whether to offer a 60-s guided breathing
// cue. Pure and DB-free; like `SedentaryDetector.evaluate` it carries its own de-dup state, so the caller
// persists `nextState` and a replayed window cannot re-fire. `ts`/`nowSec` are wall-clock unix SECONDS.
//
// Pieces: a FAST short-window RMSSD vs a SLOW EMA baseline; an EDGE trigger (fire once on the fresh
// above-to-below crossing, only after it has SUSTAINED for `sustainSeconds`); an EXERCISE GATE (HR out of
// the resting band or recent motion means metabolic, not stress); rate limit, quiet hours, master toggle,
// and never while a manual Breathe session runs.
//
// NON-CLINICAL: "stress" is an autonomic proxy (HRV down vs the user's OWN baseline); card copy says
// "HRV dipped while you were still", never "you are stressed". On fire: a confirming buzz plus a passive
// in-app card, never a push notification unless the user opted in.

public enum StressOnsetDetector {

    // MARK: - Tunables

    /// Slow-baseline EMA weight on the prior value; new RMSSD gets `1 - this`.
    public static let baselineEmaAlpha: Double = 0.98
    /// Fast RMSSD must drop below `baseline * this` to count as a dip.
    public static let dropRatio: Double = 0.6
    /// Resting HR band; outside it the dip is treated as metabolic (workout), not stress.
    public static let restingHRLow: Double = 55.0
    public static let restingHRHigh: Double = 100.0
    /// Beats in the FAST short window (latest clean beats) used for the momentary RMSSD.
    public static let fastWindowBeats: Int = 60
    /// Minimum clean beats before either RMSSD is trusted (mirrors `HRVAnalyzer.minBeats`).
    public static let minBeats: Int = HRVAnalyzer.minBeats
    /// Rate limit: at most one fire per this many seconds (15 min).
    public static let minSecondsBetweenFires: Int = 900
    /// SUSTAIN: after a fresh crossing the dip must STILL be below threshold this many seconds later. A
    /// momentary dip in a short RMSSD window is usually beat-detection wobble or posture; on 40 days of real
    /// WHOOP data the bare edge fired ~8.4x/day, of which ~13% were still below after 60 s. Holding cuts
    /// that to ~1x/day without relaxing what counts as a dip. 0 disables it (edge-only).
    public static let sustainSeconds: Int = 60
    /// Recent smoothed wrist-motion (g) at/above this means "moving" and the exercise gate suppresses the
    /// fire (same threshold as `SedentaryDetector`).
    public static let motionGateG: Double = SedentaryDetector.defaultMoveThresholdG

    // MARK: - Config

    /// The toggles and quiet-hours window, passed as plain values so the engine stays pure. All default OFF.
    public struct Config: Equatable, Sendable {
        /// Master "stress check-ins (haptic)" toggle (default OFF). Inert when off.
        public var enabled: Bool
        /// Auto-nudge sub-toggle (default OFF); when off the detector reports state but never fires.
        public var autoNudge: Bool
        /// Suppress fires during quiet hours.
        public var quietHoursEnabled: Bool
        /// Quiet-hours window, local minute-of-day [0,1440) (defaults 22:00 to 07:00).
        public var quietStartMinutes: Int
        public var quietEndMinutes: Int
        /// Strength (loops) of the confirming buzz.
        public var buzzLoops: Int

        public init(enabled: Bool = false,
                    autoNudge: Bool = false,
                    quietHoursEnabled: Bool = false,
                    quietStartMinutes: Int = SedentaryDetector.defaultQuietStartMin,
                    quietEndMinutes: Int = SedentaryDetector.defaultQuietEndMin,
                    buzzLoops: Int = 1) {
            self.enabled = enabled
            self.autoNudge = autoNudge
            self.quietHoursEnabled = quietHoursEnabled
            self.quietStartMinutes = quietStartMinutes
            self.quietEndMinutes = quietEndMinutes
            self.buzzLoops = buzzLoops
        }
    }

    // MARK: - State

    /// The state carried between evaluations (restart-safe). The caller stores it verbatim and feeds it
    /// back, like `SedentaryState`; a fresh user starts from `.initial`.
    public struct State: Equatable, Sendable {
        /// Slow RMSSD baseline (EMA), ms. 0 = uninitialised (seeds from the first trusted fast RMSSD).
        public var baselineRMSSD: Double
        /// Whether the fast RMSSD was BELOW the drop threshold on the previous evaluation (drives the edge).
        public var wasBelow: Bool
        /// Unix-seconds of the last fire (0 = never); the rate limiter.
        public var lastFireAt: Int
        /// Unix-seconds of the ARMED crossing awaiting confirmation (0 = nothing armed); the
        /// `sustainSeconds` clock. Persisted so a relaunch mid-dip cannot double-arm.
        public var pendingEdgeAt: Int

        public init(baselineRMSSD: Double = 0, wasBelow: Bool = false, lastFireAt: Int = 0,
                    pendingEdgeAt: Int = 0) {
            self.baselineRMSSD = baselineRMSSD
            self.wasBelow = wasBelow
            self.lastFireAt = lastFireAt
            self.pendingEdgeAt = pendingEdgeAt
        }

        /// Cold-start state (no baseline, not below, never fired).
        public static let initial = State()
    }

    // MARK: - Decision

    /// Why the detector did or didn't nudge; drives logs and card copy.
    public enum Reason: String, Equatable, Sendable {
        /// A fresh non-metabolic HRV dip; offer a minute to breathe.
        case onset
        /// Disabled / auto-nudge off.
        case disabled
        /// Too few clean beats to judge honestly.
        case insufficientData
        /// Fast RMSSD is at/above the threshold — no dip.
        case noDip
        /// The dip isn't a fresh edge (already below last tick, with nothing armed).
        case notAnEdge
        /// A fresh crossing is ARMED but has not held for `sustainSeconds` yet.
        case awaitingSustain
        /// Suppressed by the exercise gate (HR out of band and/or recent motion).
        case exerciseGated
        /// Inside the rate-limit window or quiet hours, or a manual session is running.
        case suppressed
    }

    /// The decision returned each evaluation. As `SedentaryDecision`: the caller acts on `shouldNudge` and
    /// stores `nextState` (always advanced).
    public struct Decision: Equatable, Sendable {
        /// True if the app should offer the breathing cue now.
        public let shouldNudge: Bool
        /// Why (whether or not it nudged).
        public let reason: Reason
        /// Buzz loops to play when `shouldNudge` (the confirming buzz).
        public let buzzLoops: Int
        /// The fast short-window RMSSD this tick (ms), or nil when insufficient.
        public let fastRMSSD: Double?
        /// The slow baseline RMSSD this tick (ms), or nil when uninitialised.
        public let baselineRMSSD: Double?
        /// The state to persist for the next evaluation.
        public let nextState: State

        public init(shouldNudge: Bool, reason: Reason, buzzLoops: Int,
                    fastRMSSD: Double?, baselineRMSSD: Double?, nextState: State) {
            self.shouldNudge = shouldNudge; self.reason = reason; self.buzzLoops = buzzLoops
            self.fastRMSSD = fastRMSSD; self.baselineRMSSD = baselineRMSSD; self.nextState = nextState
        }
    }

    // MARK: - The detector

    /// Evaluates the live window and decides whether to fire a nudge.
    ///
    /// - `rrBuffer`: rolling R-R buffer (rrMs, newest LAST); fast RMSSD is over the latest `fastWindowBeats`
    ///   clean beats and the baseline EMA absorbs each trusted fast value.
    /// - `currentHR`: latest smoothed live HR; nil is treated as out-of-band (can't confirm resting).
    /// - `recentMotionG`: recent smoothed wrist-motion (g), or nil. Missing motion alone does NOT gate:
    ///   gravity is offloaded and lags, so the resting-HR band is the real-time gate.
    /// - `sessionActive`: a manual Breathe session is running (never nudge over it).
    /// - `state`: prior persisted state; `nowSec` / `tzOffsetSec` are passed in (never read a clock).
    public static func evaluate(rrBuffer: [Int],
                                currentHR: Double?,
                                recentMotionG: Double?,
                                sessionActive: Bool,
                                state: State,
                                config: Config,
                                nowSec: Int,
                                tzOffsetSec: Int) -> Decision {

        // 1) Master gates: off means never nudge, state untouched.
        if !config.enabled || !config.autoNudge {
            return Decision(shouldNudge: false, reason: .disabled, buzzLoops: config.buzzLoops,
                            fastRMSSD: nil, baselineRMSSD: state.baselineRMSSD > 0 ? state.baselineRMSSD : nil,
                            nextState: state)
        }

        // 2) Fast RMSSD over the latest clean beats (range + Malik clean first, then the tail).
        let cleanAll = HRVAnalyzer.cleanRR(rrBuffer.map { Double($0) })
        let fastWindow = cleanAll.count > fastWindowBeats
            ? Array(cleanAll.suffix(fastWindowBeats))
            : cleanAll
        guard fastWindow.count >= minBeats, let fast = HRVAnalyzer.rmssdRaw(fastWindow), fast > 0 else {
            // Not enough signal: report, don't guess; edge state preserved.
            return Decision(shouldNudge: false, reason: .insufficientData, buzzLoops: config.buzzLoops,
                            fastRMSSD: nil, baselineRMSSD: state.baselineRMSSD > 0 ? state.baselineRMSSD : nil,
                            nextState: state)
        }

        // 3) Advance the slow baseline EMA (seeded on the first trusted value).
        var next = state
        next.baselineRMSSD = state.baselineRMSSD == 0
            ? fast
            : state.baselineRMSSD * baselineEmaAlpha + fast * (1.0 - baselineEmaAlpha)
        let baseline = next.baselineRMSSD

        // 4) Is the fast RMSSD below the drop threshold? (the dip test)
        let threshold = baseline * dropRatio
        let isBelow = fast < threshold
        // A FRESH crossing (above last tick, below now); always record the new below-state for the next tick.
        let isEdge = isBelow && !state.wasBelow
        next.wasBelow = isBelow

        // SUSTAIN: the crossing only ARMS the check. A dip that recovers before holding is discarded; one
        // that holds is CONSUMED at confirmation, so a single dip arms at most one nudge.
        if isEdge { next.pendingEdgeAt = nowSec }
        if !isBelow { next.pendingEdgeAt = 0 }

        func decide(_ nudge: Bool, _ reason: Reason) -> Decision {
            Decision(shouldNudge: nudge, reason: reason, buzzLoops: config.buzzLoops,
                     fastRMSSD: fast, baselineRMSSD: baseline, nextState: next)
        }

        if !isBelow { return decide(false, .noDip) }
        // Nothing armed while below: the dip predates this run (state restored mid-dip) or was consumed.
        guard next.pendingEdgeAt != 0 else { return decide(false, .notAnEdge) }
        if nowSec - next.pendingEdgeAt < sustainSeconds { return decide(false, .awaitingSustain) }
        next.pendingEdgeAt = 0   // consumed: proven sustained, now subject to the gates below

        // 5) Exercise gate: HR out of the resting band (or unknown), or recent motion at/above the gate, suppresses.
        let hrInBand: Bool = {
            guard let hr = currentHR else { return false }   // unknown HR can't confirm resting → gate
            return hr >= restingHRLow && hr <= restingHRHigh
        }()
        let moving: Bool = {
            guard let m = recentMotionG else { return false } // no recent gravity → motion inconclusive
            return m >= motionGateG
        }()
        if !hrInBand || moving { return decide(false, .exerciseGated) }

        // 6) Suppressors: a manual session is running, the rate limit, or quiet hours.
        if sessionActive { return decide(false, .suppressed) }
        if state.lastFireAt != 0 && (nowSec - state.lastFireAt) < minSecondsBetweenFires {
            return decide(false, .suppressed)
        }
        if config.quietHoursEnabled {
            let mod = SedentaryDetector.localMinuteOfDay(nowSec, tzOffsetSec: tzOffsetSec)
            if SedentaryDetector.windowContains(mod, startMin: config.quietStartMinutes,
                                                endMin: config.quietEndMinutes) {
                return decide(false, .suppressed)
            }
        }

        // 7) Fire; stamp the rate-limit clock.
        next.lastFireAt = nowSec
        return decide(true, .onset)
    }
}
