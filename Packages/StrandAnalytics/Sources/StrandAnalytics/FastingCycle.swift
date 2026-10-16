import Foundation

// MARK: - Fasting cycle: fast running <-> eating window open
//
// The log stores fasts only. A fast's start is the last meal and its end the first meal, so every
// eating window is the gap between two fasts, or the open gap after the newest one. That keeps one
// source of truth: editing a window moves the neighbouring fast's end or start, never a second row
// that could disagree with it. The schedule adds the plan's intent: when the open window should
// close, and when the next fast is due.

/// When fasts are meant to start: `flexible` counts the eating window from the end of the fast;
/// `fixed` starts every fast at the same local clock time (e.g. 20:00).
public enum FastingScheduleMode: Equatable, Sendable {
    case flexible
    /// Minutes after local midnight, 0..<1440.
    case fixed(startMinute: Int)
}

public struct FastingSchedule: Equatable, Sendable {
    public var plan: FastingPlan
    public var mode: FastingScheduleMode

    public init(plan: FastingPlan, mode: FastingScheduleMode) {
        self.plan = plan
        self.mode = mode
    }

    /// The eating window a flexible plan grants. Plans of a day or longer have no daily window in
    /// their name, so they get the one-meal window (OMAD's 1 h) rather than none at all.
    public var eatingWindowLength: TimeInterval { max(plan.eatingHours, 1) * 3600 }

    /// When the window opened at `end` (the first meal) is planned to close.
    public func windowClose(after end: Date, calendar: Calendar) -> Date {
        switch mode {
        case .flexible:
            return end.addingTimeInterval(eatingWindowLength)
        case .fixed(let minute):
            return Self.occurrence(of: minute, after: end, calendar: calendar)
        }
    }

    /// Fixed schedules only: the planned start at or before `date`.
    public func plannedStart(onOrBefore date: Date, calendar: Calendar) -> Date? {
        guard case .fixed(let minute) = mode else { return nil }
        let next = Self.occurrence(of: minute, after: date, calendar: calendar)
        if let back = calendar.date(byAdding: .day, value: -1, to: next), back <= date { return back }
        return next
    }

    /// Fixed schedules only: the next planned start strictly after `date`.
    public func plannedStart(after date: Date, calendar: Calendar) -> Date? {
        guard case .fixed(let minute) = mode else { return nil }
        return Self.occurrence(of: minute, after: date, calendar: calendar)
    }

    /// The first local `minute` strictly after `date`. DST gaps resolve to the next valid time.
    static func occurrence(of minute: Int, after date: Date, calendar: Calendar) -> Date {
        let m = ((minute % 1440) + 1440) % 1440
        let parts = DateComponents(hour: m / 60, minute: m % 60, second: 0)
        return calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(86_400)
    }
}

/// The open eating window: opened at the end of the last fast, planned to close at `closes`.
public struct EatingWindow: Equatable, Sendable {
    public let opens: Date
    public let closes: Date

    public init(opens: Date, closes: Date) {
        self.opens = opens
        self.closes = max(opens, closes)
    }

    public var length: TimeInterval { closes.timeIntervalSince(opens) }
    public func elapsed(now: Date) -> TimeInterval { max(0, min(now, closes).timeIntervalSince(opens)) }
    public func remaining(now: Date) -> TimeInterval { max(0, closes.timeIntervalSince(now)) }
    /// 0…1 of the window.
    public func progress(now: Date) -> Double { length > 0 ? min(1, elapsed(now: now) / length) : 1 }
}

/// Where the user stands right now.
public enum FastingCycleState: Equatable, Sendable {
    /// A fast is running.
    case fasting(FastingInterval, FastingStatus)
    /// The eating window is open and closes in the future.
    case eating(EatingWindow)
    /// The next fast is due: the window closed (or the fixed start passed) at `since`.
    case due(since: Date)
    /// Nothing is due yet: no recent fast. `next` is the fixed start, nil for a flexible plan.
    case waiting(next: Date?)

    public var isFasting: Bool { if case .fasting = self { return true } else { return false } }
}

public enum FastingCycle {

    /// How long after the planned start a fast still reads as "due". Past it, the plan is idle rather
    /// than nagging about a fast that was skipped hours ago.
    public static let dueGrace: TimeInterval = 6 * 3600

    /// Lead time for the "eating window closes soon" reminder.
    public static let closingLead: TimeInterval = 30 * 60

    /// The state at `now`. A running fast wins; otherwise the window after the newest finished fast.
    public static func state(_ intervals: [FastingInterval], schedule: FastingSchedule,
                             now: Date, calendar: Calendar) -> FastingCycleState {
        if let active = intervals.filter(\.isActive).max(by: { $0.start < $1.start }) {
            return .fasting(active, FastingEngine.status(of: active, now: now))
        }
        if let lastEnd = intervals.compactMap(\.end).filter({ $0 <= now }).max() {
            let close = schedule.windowClose(after: lastEnd, calendar: calendar)
            if now < close { return .eating(EatingWindow(opens: lastEnd, closes: close)) }
            if now.timeIntervalSince(close) <= dueGrace { return .due(since: close) }
        }
        if let planned = schedule.plannedStart(onOrBefore: now, calendar: calendar),
           now.timeIntervalSince(planned) <= dueGrace,
           intervals.allSatisfy({ ($0.end ?? now) <= planned }) {
            return .due(since: planned)
        }
        return .waiting(next: schedule.plannedStart(after: now, calendar: calendar))
    }

    /// When "start the next fast automatically" may begin a fast, backdated to the planned start, or
    /// nil. Only a due fast qualifies, and only once per planned start (`lastAutoStart` is the start
    /// the app already used), so ending or deleting an automatic fast doesn't bring it straight back.
    public static func autoStart(_ state: FastingCycleState, lastAutoStart: Date?) -> Date? {
        guard case .due(let since) = state else { return nil }
        if let lastAutoStart, abs(lastAutoStart.timeIntervalSince(since)) < 60 { return nil }
        return since
    }

    /// The upcoming reminder dates for `state`, filtered to the future. Each is nil when it doesn't apply.
    public static func reminders(_ state: FastingCycleState, now: Date) -> (goal: Date?, closing: Date?, start: Date?) {
        func future(_ d: Date?) -> Date? { d.flatMap { $0 > now.addingTimeInterval(1) ? $0 : nil } }
        switch state {
        case .fasting(_, let status):
            return (future(status.goalDate), nil, nil)
        case .eating(let window):
            let closing = window.length > closingLead * 2 ? window.closes.addingTimeInterval(-closingLead) : nil
            return (nil, future(closing), future(window.closes))
        case .due:
            return (nil, nil, nil)
        case .waiting(let next):
            return (nil, nil, future(next))
        }
    }

    /// The part of the full cycle the fasting phase takes on the ring (fasting goal + eating window).
    public static func ringFastingShare(goal: TimeInterval, eatingWindow: TimeInterval) -> Double {
        let total = max(goal, 0) + max(eatingWindow, 0)
        return total > 0 ? max(goal, 0) / total : 1
    }
}
