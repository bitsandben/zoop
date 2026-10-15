import Foundation

// CoachMorningRules.swift - the deterministic morning coach.
//
// Turns the morning's numbers into a readiness band and up to three suggestions. This is the coach
// that always works: offline, with no provider configured, and as the safety net when a cloud reply
// cannot be parsed. A cloud provider may reword what it proposes but never invents the actions, so
// accepting a suggestion always does something the app can actually carry out.

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
        case lowRecoveryRest, plannedRoutineEaseOff, plannedRoutineGo
        case greenRoutine, greenPush, moderateSession
        case sleepDebtBedtime, shortNightBedtime
        case hrvBelowRange, highStress
        case fastingNext, fastingShorten
        case steadyDay
    }

    public struct Routine: Equatable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public struct Fasting: Equatable, Sendable {
        public let active: Bool
        /// When the next fast is due (minute of day), nil when unknown.
        public let nextStartMinute: Int?
        public let planId: String
        public let fastingHours: Double
        public init(active: Bool, nextStartMinute: Int?, planId: String, fastingHours: Double) {
            self.active = active
            self.nextStartMinute = nextStartMinute
            self.planId = planId
            self.fastingHours = fastingHours
        }
    }

    public struct Input: Equatable, Sendable {
        public var recovery: Double?
        public var hrv: Double?
        /// Trailing mean HRV, excluding today.
        public var hrvBaseline: Double?
        public var sleepMin: Double?
        /// Current sleep debt in minutes (0 when balanced).
        public var sleepDebtMin: Double = 0
        /// Tonight's bedtime from the sleep planner (minute of day), nil when no wake time is known.
        public var bedtimeMinute: Int?
        /// Today's optimal Day Strain band on the 0-21 axis.
        public var strainTarget: ClosedRange<Int>?
        /// Lift Log programs planned for today.
        public var plannedRoutines: [Routine] = []
        /// Programs the user could run, most suitable first (the caller orders them).
        public var availableRoutines: [Routine] = []
        /// Yesterday's daily stress level on the shared 0-3 scale.
        public var stressLevel: Double?
        /// Nil for people who do not fast.
        public var fasting: Fasting?
        public var suppressedReasons: Set<String> = []
        public var suppressedKinds: Set<CoachSuggestion.Kind> = []

        public init() {}
    }

    public struct Candidate: Equatable, Sendable {
        public let kind: CoachSuggestion.Kind
        public let reason: Reason
        public let action: CoachSuggestion.Action
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
    /// Debt worth an earlier night: the ledger's own on-target band.
    static let debtWorthActing = SleepDebt.onTargetBandMin
    static let shortNightMin: Double = 360
    /// The high stress band floor on the 0-3 scale.
    static let highStress = DaytimeStress.highBandFloor
    /// A fast at least this long is worth shortening on a low-recovery day.
    static let longFastHours: Double = 18
    public static let maxSuggestions = 3

    /// The morning plan. Pure: same input, same plan.
    public static func evaluate(_ input: Input) -> Plan {
        let readiness = Readiness(recovery: input.recovery)
        var out: [Candidate] = []
        if let training = trainingCandidate(input, readiness) { out.append(training) }
        if let sleep = sleepCandidate(input) { out.append(sleep) }
        out += habitCandidates(input)
        if let fast = fastingCandidate(input, readiness) { out.append(fast) }

        let allowed = out.filter {
            !input.suppressedReasons.contains($0.reason.rawValue) && !input.suppressedKinds.contains($0.kind)
        }
        var picked = Array(allowed.prefix(maxSuggestions))
        if picked.isEmpty, !input.suppressedReasons.contains(Reason.steadyDay.rawValue), readiness != .unknown {
            picked = [Candidate(kind: .general, reason: .steadyDay, action: .none)]
        }
        return Plan(readiness: readiness, candidates: picked)
    }

    // MARK: - Rules

    /// One training suggestion at most: the day's training is a single decision.
    private static func trainingCandidate(_ input: Input, _ readiness: Readiness) -> Candidate? {
        let band = input.strainTarget.map { CoachSuggestion.Action.strainTarget(low: $0.lowerBound, high: $0.upperBound) }
            ?? .none
        let planned = !input.plannedRoutines.isEmpty
        switch readiness {
        case .unknown:
            return nil
        case .low:
            return planned
                ? Candidate(kind: .trainingToday, reason: .plannedRoutineEaseOff, action: band)
                : Candidate(kind: .recovery, reason: .lowRecoveryRest, action: band)
        case .medium:
            return planned
                ? Candidate(kind: .trainingToday, reason: .plannedRoutineGo, action: band)
                : Candidate(kind: .trainingToday, reason: .moderateSession, action: band)
        case .high:
            if planned { return Candidate(kind: .trainingToday, reason: .plannedRoutineGo, action: band) }
            if let next = input.availableRoutines.first {
                return Candidate(kind: .routine, reason: .greenRoutine,
                                 action: .routine(programId: next.id, name: next.name))
            }
            return Candidate(kind: .trainingToday, reason: .greenPush, action: band)
        }
    }

    /// An earlier night when there is debt to pay back or last night was short, and only when the
    /// planner knows a bedtime to propose.
    private static func sleepCandidate(_ input: Input) -> Candidate? {
        guard let bed = input.bedtimeMinute else { return nil }
        let minute = ((bed % 1440) + 1440) % 1440
        if input.sleepDebtMin >= debtWorthActing {
            return Candidate(kind: .sleepTiming, reason: .sleepDebtBedtime, action: .bedtime(minuteOfDay: minute))
        }
        if let s = input.sleepMin, s < shortNightMin {
            return Candidate(kind: .sleepTiming, reason: .shortNightBedtime, action: .bedtime(minuteOfDay: minute))
        }
        return nil
    }

    /// HRV under range comes before a stressful yesterday: it is the overnight signal.
    private static func habitCandidates(_ input: Input) -> [Candidate] {
        var out: [Candidate] = []
        if let h = input.hrv, let base = input.hrvBaseline, base > 0, h < hrvLowRatio * base {
            out.append(Candidate(kind: .habit, reason: .hrvBelowRange, action: .none))
        }
        if let s = input.stressLevel, s >= highStress {
            out.append(Candidate(kind: .habit, reason: .highStress, action: .none))
        }
        return out
    }

    /// Only for people who fast and are not fasting right now.
    private static func fastingCandidate(_ input: Input, _ readiness: Readiness) -> Candidate? {
        guard let f = input.fasting, !f.active else { return nil }
        if readiness == .low, f.fastingHours >= longFastHours {
            return Candidate(kind: .fasting, reason: .fastingShorten, action: .none)
        }
        guard let start = f.nextStartMinute else { return nil }
        return Candidate(kind: .fasting, reason: .fastingNext,
                         action: .fastingStart(minuteOfDay: ((start % 1440) + 1440) % 1440, planId: f.planId))
    }
}
