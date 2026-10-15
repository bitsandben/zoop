import Foundation

// SmartAlarmNight: one night's diagnostics record for the goal-based smart alarm, and the pure reading of it
// (did the app get to run in the window, and why did the wake happen when it did).
//
// Each field is something the app observed itself. Nothing here claims the strap buzzed unless the strap's own
// "alarm executed" event was received (`strapFiredAt`), and a check counts as run only if it actually ran.

public struct SmartAlarmNight: Codable, Equatable, Identifiable, Sendable {

    public var id: Int { deadline }

    /// The window end, the instant armed on the strap as the hard deadline (epoch seconds).
    public var deadline: Int
    public var windowStart: Int
    public var settings: GoalWake.Settings
    /// Tonight's sleep need when the night was set up (minutes).
    public var needMin: Double?
    /// The check times planned for the window.
    public var plannedChecks: [Int]
    public var arms: [Arm] = []
    public var checks: [Check] = []
    public var events: [Event] = []
    public var earlyWake: EarlyWake?
    /// When the strap reported its alarm executed (event 57) inside this night's window, if received.
    public var strapFiredAt: Int?
    /// The arm-readback verdict (`AlarmReadback.Verdict`) for the last arm, when one was attributable.
    public var readback: String?

    public init(deadline: Int, windowStart: Int, settings: GoalWake.Settings, needMin: Double?,
                plannedChecks: [Int]) {
        self.deadline = deadline
        self.windowStart = windowStart
        self.settings = settings
        self.needMin = needMin
        self.plannedChecks = plannedChecks
    }

    public struct Arm: Codable, Equatable, Sendable {
        public var at: Int
        public var target: Int
        /// The command channel was ready, so the arm went out now rather than being queued.
        public var connected: Bool
        public init(at: Int, target: Int, connected: Bool) {
            self.at = at; self.target = target; self.connected = connected
        }
    }

    public enum SyncResult: String, Codable, Sendable {
        /// The strap reported its history complete after the request.
        case completed
        /// A sync started but did not finish before the check read the data.
        case timedOut
        /// The sync reported an issue after it started.
        case failed
        /// Connected, but the sync gate did not start one (busy or rate-limited).
        case notStarted
        /// No strap connection at the check.
        case noStrap
    }

    public struct Check: Codable, Equatable, Sendable {
        public var ranAt: Int
        public var evaluatedAt: Int
        public var connected: Bool
        public var sync: SyncResult
        /// Age of the newest heart-rate / gravity sample at evaluation (seconds); nil when none in reach.
        public var hrAgeS: Int?
        public var gravityAgeS: Int?
        public var asleepMin: Double?
        public var needMin: Double?
        /// The partial-night recovery ESTIMATE, when one could be computed.
        public var recoveryEstimate: Double?
        /// `SmartWake.Signal` raw value, nil when no light-sleep signal.
        public var lightSleep: String?
        /// "wake" or a `GoalWake.Hold` raw value.
        public var decision: String
        public init(ranAt: Int, evaluatedAt: Int, connected: Bool, sync: SyncResult, hrAgeS: Int?, gravityAgeS: Int?,
                    asleepMin: Double?, needMin: Double?, recoveryEstimate: Double?, lightSleep: String?,
                    decision: String) {
            self.ranAt = ranAt; self.evaluatedAt = evaluatedAt; self.connected = connected; self.sync = sync
            self.hrAgeS = hrAgeS; self.gravityAgeS = gravityAgeS; self.asleepMin = asleepMin
            self.needMin = needMin; self.recoveryEstimate = recoveryEstimate; self.lightSleep = lightSleep
            self.decision = decision
        }
    }

    public enum EventKind: String, Codable, Sendable {
        case foreground, background, backgroundLaunch, bleRestore, syncCompleted, strapAlarmFired, deadlineRearmed
    }

    public struct Event: Codable, Equatable, Sendable {
        public var at: Int
        public var kind: EventKind
        public init(at: Int, kind: EventKind) { self.at = at; self.kind = kind }
    }

    public struct EarlyWake: Codable, Equatable, Sendable {
        public var decidedAt: Int
        public var wakeAt: Int
        public var reason: GoalWake.Reason
        public init(decidedAt: Int, wakeAt: Int, reason: GoalWake.Reason) {
            self.decidedAt = decidedAt; self.wakeAt = wakeAt; self.reason = reason
        }
    }
}

// MARK: - Reading a night

extension SmartAlarmNight {

    /// A planned check counts as covered when a check ran from a minute before it to the next planned slot.
    public static let coverSlackS = 60

    public enum Coverage: String, Sendable {
        /// Every relevant check ran: the app could decide all night.
        case full
        /// Some ran, some did not.
        case partial
        /// No check ran in the window.
        case none
        /// The window has not ended yet.
        case pending
        /// A plain alarm with no window: nothing to check.
        case notApplicable
    }

    public enum Outcome: Equatable, Sendable {
        case pending
        case earlyWake(at: Int, reason: GoalWake.Reason)
        /// Rang at the deadline after checks ran without the goal being met.
        case deadlineGoalNotMet
        /// Rang at the deadline with no check run in the window.
        case deadlineAppNotRunning
        /// A plain alarm at the deadline.
        case deadlineFixed
    }

    /// Planned checks that still mattered: those before an early wake was decided.
    public var relevantChecks: [Int] {
        guard let e = earlyWake else { return plannedChecks }
        return plannedChecks.filter { $0 <= e.decidedAt }
    }

    public func slotIsCovered(_ slot: Int, intervalS: Int) -> Bool {
        checks.contains { $0.ranAt >= slot - Self.coverSlackS && $0.ranAt < slot + intervalS }
    }

    /// Planned checks with no check run near them: the app was not running (or not woken) then.
    public func missedChecks(intervalS: Int) -> [Int] {
        relevantChecks.filter { !slotIsCovered($0, intervalS: intervalS) }
    }

    public var checksInWindow: [Check] {
        checks.filter { $0.ranAt >= windowStart - Self.coverSlackS && $0.ranAt <= deadline }
    }

    public func coverage(now: Int, intervalS: Int) -> Coverage {
        if plannedChecks.isEmpty { return .notApplicable }
        if now < deadline && earlyWake == nil { return .pending }
        let relevant = relevantChecks
        let missed = missedChecks(intervalS: intervalS).count
        if checksInWindow.isEmpty { return .none }
        return missed == 0 && !relevant.isEmpty ? .full : .partial
    }

    public func outcome(now: Int) -> Outcome {
        if let e = earlyWake { return .earlyWake(at: e.wakeAt, reason: e.reason) }
        if now < deadline { return .pending }
        if plannedChecks.isEmpty { return .deadlineFixed }
        return checksInWindow.isEmpty ? .deadlineAppNotRunning : .deadlineGoalNotMet
    }

    /// Records newest first, at most `keep`, one per deadline (a later copy replaces an earlier one).
    public static func pruned(_ nights: [SmartAlarmNight], keep: Int = 30) -> [SmartAlarmNight] {
        var byDeadline: [Int: SmartAlarmNight] = [:]
        for n in nights { byDeadline[n.deadline] = n }
        return Array(byDeadline.values.sorted { $0.deadline > $1.deadline }.prefix(keep))
    }

    /// "In 5 of 7 nights the app could act": nights whose window has ended, and of those the ones with at
    /// least one check run in the window.
    public static func summary(_ nights: [SmartAlarmNight], now: Int, intervalS: Int) -> (acted: Int, total: Int) {
        let judged = nights.filter {
            let c = $0.coverage(now: now, intervalS: intervalS)
            return c != .pending && c != .notApplicable
        }
        return (judged.filter { $0.coverage(now: now, intervalS: intervalS) != .none }.count, judged.count)
    }
}
