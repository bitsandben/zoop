import Foundation

// CoachMorningRules.swift - the deterministic morning coach.
//
// Turns the morning's numbers into a readiness band and up to two prioritised suggestions. This is
// the coach that always works: offline, with no provider configured, and as the safety net when a
// cloud reply cannot be used. It returns structure only (reason codes, actions and the numbers each
// suggestion rests on); the app turns that into sentences in the app language. A cloud provider may
// reword what it proposes but never invents the actions, so accepting always does something real.
//
// The rules themselves are in CoachMorningRules+Rules.swift.

public enum CoachMorningRules {

    /// The morning's readiness, on the same cut points as the Charge bands (`CoachSuggestions`).
    public enum Readiness: String, Equatable, Sendable {
        case high, medium, low, unknown

        public init(recovery: Double?) {
            guard let r = recovery else { self = .unknown; return }
            switch r {
            case CoachMorningRules.greenCutoff...: self = .high
            case CoachMorningRules.redCutoff..<CoachMorningRules.greenCutoff: self = .medium
            default: self = .low
            }
        }
    }

    /// Why a suggestion was made. The raw value is stored with the suggestion and is what the
    /// dismissal feedback matches on, so these strings must never be renamed.
    public enum Reason: String, CaseIterable, Sendable {
        // The day's training (one per day).
        case illnessRest, lowRecoveryRest, poorSleepEasy, plannedRoutineEaseOff
        case hrvTrendCaution, loadDeload
        case routineBackOnTrack, routineMissed
        case plannedRoutineGo, greenRoutine, greenPush, trendGreenLight, moderateSession
        // Tonight.
        case sleepDebtBedtime, shortNightBedtime, bedtimeRegularity
        // Stress and habits.
        case stressPeakBreathe, highStress, hrvBelowRange
        // Fasting, only when a long fast meets a body that needs care.
        case fastingBreak
        case steadyDay
    }

    /// One piece of data a suggestion rests on. The app renders each as a "because" clause.
    public enum Evidence: Equatable, Sendable {
        case recovery(percent: Int)
        case sleep(minutes: Int)
        case sleepDebt(minutes: Int)
        /// HRV beyond its normal for `days` mornings in a row; `deltaPercent` is the weekly drift.
        case hrvTrend(days: Int, deltaPercent: Int)
        case rhrTrend(days: Int, deltaPercent: Int)
        case hrvToday(ms: Int, typicalMs: Int)
        /// This week's load as a share of the user's normal (100 = normal).
        case load(percentOfNormal: Int)
        case missedRoutine(missed: Int, planned: Int)
        case planned(name: String)
        case bedtimeDrift(lastMinute: Int, usualMinute: Int)
        case stressPeak(hour: Int)
        case stressYesterday(level: Double)
        case fasting(hours: Int)
        case illness
    }

    public struct Routine: Equatable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// HRV or resting HR against the personal normal (`BodyInsights.direction`).
    public struct Trend: Equatable, Sendable {
        /// True when the latest readings sit below the normal.
        public let below: Bool
        public let streakDays: Int
        public let deltaPercent: Double
        public init(below: Bool, streakDays: Int, deltaPercent: Double) {
            self.below = below
            self.streakDays = streakDays
            self.deltaPercent = deltaPercent
        }
    }

    /// Only set while a fast is running.
    public struct Fasting: Equatable, Sendable {
        public let elapsedHours: Double
        public let targetHours: Double
        public init(elapsedHours: Double, targetHours: Double) {
            self.elapsedHours = elapsedHours
            self.targetHours = targetHours
        }
    }

    public struct Input: Equatable, Sendable {
        public var recovery: Double?
        public var hrv: Double?
        /// Trailing mean HRV, excluding today.
        public var hrvBaseline: Double?
        public var hrvTrend: Trend?
        public var rhrTrend: Trend?
        public var sleepMin: Double?
        /// Current sleep debt in minutes (0 when balanced).
        public var sleepDebtMin: Double = 0
        /// Tonight's bedtime from the sleep planner (minute of day), nil when no wake time is known.
        public var bedtimeMinute: Int?
        /// Centre of the bedtime window before the user's best recoveries (minute of day).
        public var bestBedtimeMinute: Int?
        /// When last night started (minute of day).
        public var lastBedtimeMinute: Int?
        /// The user's habitual bedtime (median of recent nights, minute of day).
        public var usualBedtimeMinute: Int?
        /// Today's optimal Day Strain band on the 0-21 axis.
        public var strainTarget: ClosedRange<Int>?
        /// This week's load against the user's normal (`TrainingLoadGauge`).
        public var loadState: TrainingLoadGauge.State?
        public var loadRatio: Double?
        /// Lift Log programs planned for today.
        public var plannedRoutines: [Routine] = []
        /// Programs the user could run, most suitable first (the caller orders them).
        public var availableRoutines: [Routine] = []
        /// Planned training days of the last two weeks against what was done.
        public var adherence: CoachAdherence.Result?
        /// Yesterday's daily stress level on the shared 0-3 scale.
        public var stressLevel: Double?
        /// The hour stress usually peaks (`BodyInsights.stressTiming`) and its mean level there.
        public var stressPeakHour: Int?
        public var stressPeakLevel: Double?
        /// The illness engine raised a signal, or the user logged feeling unwell.
        public var illness = false
        /// Nil unless a fast is running.
        public var fasting: Fasting?
        public var suppressedReasons: Set<String> = []
        public var suppressedKinds: Set<CoachSuggestion.Kind> = []

        public init() {}
    }

    public struct Candidate: Equatable, Sendable {
        public let kind: CoachSuggestion.Kind
        public let reason: Reason
        public let action: CoachSuggestion.Action
        /// What the suggestion rests on, most telling first (at most two).
        public let evidence: [Evidence]
        /// Higher comes first.
        public let priority: Int

        public init(kind: CoachSuggestion.Kind, reason: Reason, action: CoachSuggestion.Action,
                    evidence: [Evidence] = [], priority: Int = 0) {
            self.kind = kind
            self.reason = reason
            self.action = action
            self.evidence = Array(evidence.prefix(2))
            self.priority = priority
        }
    }

    public struct Plan: Equatable, Sendable {
        public let readiness: Readiness
        /// Ordered by priority, at most `maxSuggestions`.
        public let candidates: [Candidate]
    }

    static let redCutoff: Double = 34
    static let greenCutoff: Double = 67
    /// HRV under 85 % of its trailing mean counts as "below range", the `CoachSuggestions` cut.
    static let hrvLowRatio = 0.85
    /// Debt worth an earlier night: three quarters of an hour (the ledger's 10-minute on-target band is
    /// too fine to move a bedtime for).
    static let debtWorthActing: Double = 45
    /// Debt this large counts as a poor night for the day's training, like a short night does.
    static let heavyDebtMin: Double = 120
    static let shortNightMin: Double = 360
    /// The high stress band floor on the 0-3 scale.
    static let highStress = DaytimeStress.highBandFloor
    /// A usual peak this high is worth a planned breather even after a calm yesterday.
    static let peakWorthBreathing = 1.5
    /// A run of mornings this long is a trend worth acting on (`BodyInsights.minStreak`).
    static let trendStreak = 3
    /// Planned sessions missed in the window before the coach nudges.
    static let missedWorthNudge = 2
    /// Last night started this far from the usual bedtime before regularity is worth a word.
    static let bedtimeDriftMin = 60
    /// A proposed bedtime is never more than this much earlier than the usual one.
    static let earliestBeforeUsualMin = 60
    /// A running fast at least this long (planned or elapsed) is worth breaking on a low day.
    static let longFastHours: Double = 16
    public static let maxSuggestions = 2

    /// The morning plan. Pure: same input, same plan.
    public static func evaluate(_ input: Input) -> Plan {
        let readiness = Readiness(recovery: input.recovery)
        let all = [trainingCandidate(input, readiness), sleepCandidate(input),
                   stressCandidate(input), hrvCandidate(input, readiness), fastingCandidate(input, readiness)]
            .compactMap { $0 }
        let allowed = all.filter {
            !input.suppressedReasons.contains($0.reason.rawValue) && !input.suppressedKinds.contains($0.kind)
        }
        // Stable: equal priorities keep the slot order above.
        var picked = allowed.enumerated()
            .sorted { $0.element.priority != $1.element.priority
                ? $0.element.priority > $1.element.priority : $0.offset < $1.offset }
            .prefix(maxSuggestions)
            .map(\.element)
        if picked.isEmpty, !input.suppressedReasons.contains(Reason.steadyDay.rawValue), readiness != .unknown {
            picked = [Candidate(kind: .general, reason: .steadyDay, action: .none,
                                evidence: recoveryEvidence(input), priority: 0)]
        }
        return Plan(readiness: readiness, candidates: picked)
    }

    // MARK: - Shared helpers

    static func recoveryEvidence(_ input: Input) -> [Evidence] {
        input.recovery.map { [.recovery(percent: Int($0.rounded()))] } ?? []
    }

    static func minuteOfDay(_ minute: Int) -> Int { ((minute % 1440) + 1440) % 1440 }

    /// Minutes from midnight with the evening negative (22:00 = -120, 01:00 = 60), for comparing bedtimes.
    static func signed(_ minute: Int) -> Int {
        let m = minuteOfDay(minute)
        return m >= 12 * 60 ? m - 1440 : m
    }

    /// A bedtime a person will actually keep: no more than an hour before their usual one, never before
    /// 21:00 unless they habitually sleep earlier, rounded to the quarter hour.
    public static func reasonableBedtime(_ proposed: Int, usual: Int?) -> Int {
        let floor21 = -3 * 60
        let lower = usual.map { u -> Int in
            let su = signed(u)
            return max(su - earliestBeforeUsualMin, min(su, floor21))
        } ?? floor21
        let clamped = max(signed(proposed), lower)
        let rounded = Int((Double(clamped) / 15).rounded()) * 15
        return minuteOfDay(rounded)
    }

    /// Distance between two clock minutes, across midnight (0...720).
    static func clockDistance(_ a: Int, _ b: Int) -> Int {
        let d = abs(minuteOfDay(a) - minuteOfDay(b))
        return min(d, 1440 - d)
    }
}
