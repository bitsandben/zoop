import Foundation

// GoalWake: the experimental goal-based smart alarm (fixed time, sleep need reached, recovery reached).
//
// The strap alarm stays armed at the window END all night, which is the hard deadline; this only ever decides
// whether to move it EARLIER, once, to `now + earlyWakeLeadS`. `decide` never returns a wake before the window
// start or later than `windowEnd - deadlineMarginS`, so the deadline can only be pre-empted, never postponed.
// Pure and clock-free (every time is an epoch second passed in) so the bounds are tested without a strap.

public enum GoalWake {

    /// What the alarm waits for inside its window.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// The plain alarm at the window end; inside the window only light sleep moves it earlier.
        case fixedTime
        /// Wake once tonight's asleep minutes reach tonight's sleep need.
        case sleepNeed
        /// Wake once the partial-night recovery ESTIMATE reaches the threshold.
        case recovery
    }

    /// Recovery threshold default: the green band starts here (`RecoveryScorer.bandYellowMax`).
    public static let defaultRecoveryThreshold = Int(RecoveryScorer.bandYellowMax)
    /// The early wake is armed this far ahead, so the arm burst reaches the strap before it is due.
    public static let earlyWakeLeadS = 30
    /// No early wake this close to the deadline: the deadline alarm is already about to ring.
    public static let deadlineMarginS = 120
    /// With the goal met but no light-sleep signal, wake anyway once this far into the window.
    public static let defaultLightSleepGraceMin = 10

    /// The wake window in epoch seconds. `end` is the deadline the strap is armed at.
    public struct Window: Equatable, Codable, Sendable {
        public let start: Int
        public let end: Int
        public init(start: Int, end: Int) {
            self.start = min(start, end)
            self.end = end
        }
        /// The window ending at `deadline`, `minutes` long.
        public init(deadline: Int, minutes: Int) {
            self.init(start: deadline - max(0, minutes) * 60, end: deadline)
        }
    }

    public struct Settings: Equatable, Codable, Sendable {
        public var mode: Mode
        /// Recovery threshold (0–100); read only in `.recovery`.
        public var recoveryThreshold: Double
        /// Prefer waking in light sleep once the goal is met (goal modes only; `.fixedTime` always needs it).
        public var preferLightSleep: Bool
        public var lightSleepGraceMin: Int
        public init(mode: Mode, recoveryThreshold: Double = Double(GoalWake.defaultRecoveryThreshold),
                    preferLightSleep: Bool = true, lightSleepGraceMin: Int = GoalWake.defaultLightSleepGraceMin) {
            self.mode = mode
            self.recoveryThreshold = recoveryThreshold
            self.preferLightSleep = preferLightSleep
            self.lightSleepGraceMin = lightSleepGraceMin
        }
    }

    /// What one check knows. nil means "not known", never zero.
    public struct Inputs: Equatable, Sendable {
        public var now: Int
        public var asleepMin: Double?
        public var needMin: Double?
        public var recovery: Double?
        public var lightSleep: Bool
        /// The live heart-rate read (`LiveWake`, heuristic) when the strap's live stream was flowing; nil otherwise.
        public var live: LiveWake.State?
        public init(now: Int, asleepMin: Double? = nil, needMin: Double? = nil,
                    recovery: Double? = nil, lightSleep: Bool = false, live: LiveWake.State? = nil) {
            self.now = now; self.asleepMin = asleepMin; self.needMin = needMin
            self.recovery = recovery; self.lightSleep = lightSleep; self.live = live
        }

        /// Light sleep as the decision reads it: the live read when it has a clear answer (light or awake yes,
        /// deep no), else the synced-data signal (`lightSleep`).
        public var effectiveLightSleep: Bool {
            switch live {
            case .awake?, .light?: return true
            case .deep?: return false
            case .steady?, nil: return lightSleep
            }
        }
    }

    public enum Condition: String, Codable, Sendable {
        case met, notMet
        /// The value the mode needs could not be computed (no data, calibrating).
        case unknown
    }

    /// Why an early wake was chosen.
    public enum Reason: String, Codable, Sendable {
        case sleepNeedReached, recoveryReached, lightSleep
        /// The live heart rate read clearly awake inside the window: waking now beats a later wake from deep sleep.
        case awake
    }

    /// Why a check did not wake.
    public enum Hold: String, Codable, Sendable {
        case beforeWindow
        /// Within `deadlineMarginS` of the deadline: the armed deadline rings.
        case deadlineClose
        case conditionNotMet
        case noData
        case waitingForLightSleep
    }

    public enum Decision: Equatable, Sendable {
        case hold(Hold)
        /// Arm the strap at `at` (epoch seconds), once.
        case wake(at: Int, reason: Reason)
    }

    /// Whether the mode's goal is met. `.fixedTime` has no goal and reads `.notMet`.
    public static func condition(_ s: Settings, _ i: Inputs) -> Condition {
        switch s.mode {
        case .fixedTime:
            return .notMet
        case .sleepNeed:
            guard let asleep = i.asleepMin, let need = i.needMin, need > 0 else { return .unknown }
            return asleep >= need ? .met : .notMet
        case .recovery:
            guard let r = i.recovery else { return .unknown }
            return r >= s.recoveryThreshold ? .met : .notMet
        }
    }

    /// The early-wake instant for a check at `now`, or nil when it would land inside the deadline margin.
    /// Never before the window start (a check before the start returns nil) and never after the deadline.
    public static func wakeTime(now: Int, window: Window) -> Int? {
        guard now >= window.start else { return nil }
        let at = now + earlyWakeLeadS
        guard at <= window.end - deadlineMarginS else { return nil }
        return at
    }

    /// The decision for one check inside the window. A clear live "awake" wakes in every mode (the wearer is
    /// already up; the goal no longer protects any sleep), light sleep follows `effectiveLightSleep`.
    public static func decide(window: Window, settings s: Settings, inputs i: Inputs) -> Decision {
        guard i.now >= window.start else { return .hold(.beforeWindow) }
        guard let at = wakeTime(now: i.now, window: window) else { return .hold(.deadlineClose) }
        if i.live == .awake { return .wake(at: at, reason: .awake) }
        let light = i.effectiveLightSleep
        if s.mode == .fixedTime {
            return light ? .wake(at: at, reason: .lightSleep) : .hold(.waitingForLightSleep)
        }
        switch condition(s, i) {
        case .unknown: return .hold(.noData)
        case .notMet: return .hold(.conditionNotMet)
        case .met:
            let reason: Reason = s.mode == .sleepNeed ? .sleepNeedReached : .recoveryReached
            let intoWindowMin = (i.now - window.start) / 60
            if !s.preferLightSleep || light || intoWindowMin >= s.lightSleepGraceMin {
                return .wake(at: at, reason: reason)
            }
            return .hold(.waitingForLightSleep)
        }
    }

    /// The check times inside a window: the start, then every `intervalS`, while an early wake is still possible.
    public static func plannedChecks(window: Window, intervalS: Int) -> [Int] {
        guard intervalS > 0 else { return [] }
        var out: [Int] = []
        var t = window.start
        while wakeTime(now: t, window: window) != nil {
            out.append(t)
            t += intervalS
        }
        return out
    }
}

// MARK: - Night so far

/// Sleep so far tonight, from the sessions the sleep detector finds in the data synced up to now.
public enum NightProgress {

    public struct Progress: Equatable, Sendable {
        /// Start of the first session tonight (sleep onset).
        public let onset: Int
        /// Asleep minutes (in-bed minus wake) summed over tonight's sessions.
        public let asleepMin: Double
        /// Duration-weighted mean of the sessions' 5-min RMSSD; nil when no session carries one.
        public let hrv: Double?
        /// Lowest session resting HR; nil when none carries one.
        public let restingHR: Double?
        /// End of the newest session, i.e. how far the detector could see.
        public let lastSessionEnd: Int
    }

    /// Sessions that started within `lookbackS` of `now` and are at least `minSessionMin` long.
    public static func tonight(sessions: [SleepSession], now: Int, lookbackS: Int = 14 * 3600,
                               minSessionMin: Double = 20) -> Progress? {
        let tonight = sessions
            .filter { $0.start >= now - lookbackS && $0.start < now && Double($0.end - $0.start) >= minSessionMin * 60 }
            .sorted { $0.start < $1.start }
        guard let first = tonight.first, let last = tonight.last else { return nil }
        let asleepS = tonight.reduce(0.0) { $0 + asleepSeconds($1, now: now) }
        var hrvSum = 0.0, hrvWeight = 0.0
        for s in tonight {
            guard let h = s.avgHRV, h.isFinite else { continue }
            let w = Double(min(s.end, now) - s.start)
            hrvSum += h * w; hrvWeight += w
        }
        let rhr = tonight.compactMap(\.restingHR).min().map(Double.init)
        return Progress(onset: first.start, asleepMin: asleepS / 60,
                        hrv: hrvWeight > 0 ? hrvSum / hrvWeight : nil,
                        restingHR: rhr, lastSessionEnd: last.end)
    }

    /// Non-wake stage time up to `now`; a session without stages falls back to in-bed time x efficiency.
    static func asleepSeconds(_ s: SleepSession, now: Int) -> Double {
        let end = min(s.end, now)
        guard end > s.start else { return 0 }
        if s.stages.isEmpty { return Double(end - s.start) * max(0, min(1, s.efficiency)) }
        return s.stages.reduce(0.0) { acc, seg in
            guard seg.stage != "wake" else { return acc }
            return acc + Double(max(0, min(seg.end, end) - max(seg.start, s.start)))
        }
    }
}

// MARK: - Partial-night recovery estimate

/// An ESTIMATE of this morning's recovery from the night so far: the same `RecoveryScorer` with the inputs that
/// exist mid-night (HRV and resting HR so far vs the personal baselines, sleep sufficiency so far). Respiration,
/// skin temperature and the rest of the night are missing, so it is not the morning score and must be labelled
/// as an estimate wherever it is shown.
public enum PartialNightRecovery {

    /// Too little sleep for HRV / resting HR to mean anything yet.
    public static let minAsleepMin = 90.0

    public struct Estimate: Equatable, Codable, Sendable {
        public let score: Double
        public let hrv: Double
        public let restingHR: Double
        public let asleepMin: Double
        /// Always true: this is a mid-night estimate, not the morning recovery.
        public var isEstimate: Bool { true }
    }

    /// nil while there is too little sleep, no HRV / resting HR so far, or no usable HRV baseline.
    public static func estimate(hrvSoFar: Double?, restingHRSoFar: Double?, asleepMin: Double, needMin: Double?,
                                hrvBaseline: BaselineState?, rhrBaseline: BaselineState?) -> Estimate? {
        guard asleepMin >= minAsleepMin, let hrv = hrvSoFar, let rhr = restingHRSoFar,
              hrv.isFinite, rhr.isFinite, let hrvBase = hrvBaseline else { return nil }
        let sleepPerf = needMin.map {
            AnalyticsEngine.Rest.sufficiency(tstSeconds: asleepMin * 60, needHours: $0 / 60)
        }
        guard let score = RecoveryScorer.recovery(hrv: hrv, rhr: rhr, resp: nil, hrvBaseline: hrvBase,
                                                  rhrBaseline: rhrBaseline, respBaseline: nil,
                                                  sleepPerf: sleepPerf) else { return nil }
        return Estimate(score: score, hrv: hrv, restingHR: rhr, asleepMin: asleepMin)
    }
}
