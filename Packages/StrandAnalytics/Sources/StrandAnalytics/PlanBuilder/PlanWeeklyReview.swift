import Foundation

/// One planned weekly session of a training plan.
public struct PlanSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// `Calendar` weekday: 1 = Sunday … 7 = Saturday.
    public var weekday: Int
    public var title: String
    /// A sport catalogue name (`KnownWorkoutType` raw value) or free text.
    public var sport: String
    public var minutes: Int
    /// Local "HH:mm"; nil when the plan names no time.
    public var time: String?
    /// The Lift Log program behind a strength session.
    public var programId: String?

    public init(id: String, weekday: Int, title: String, sport: String, minutes: Int,
                time: String? = nil, programId: String? = nil) {
        self.id = id
        self.weekday = weekday
        self.title = title
        self.sport = sport
        self.minutes = minutes
        self.time = time
        self.programId = programId
    }
}

// MARK: - Weekly review
//
// Once a week the plan is checked against what actually happened and how the body is doing. The rules
// are deterministic and each change carries the one reason that triggered it; a coach model may only
// rephrase the reasons or drop changes, never invent one. At most one change per session.

public enum PlanWeeklyReview {

    public enum LoadState: String, Codable, Sendable, Equatable { case unknown, low, optimal, high }

    public struct Signals: Equatable, Sendable {
        /// Per session id: done flags for recent weeks, oldest first (the last entry is last week).
        public var adherence: [String: [Bool]]
        /// Workouts started per weekday (1…7) over the last four weeks: where training actually happens.
        public var activeWeekdays: [Int: Int]
        /// Daily recovery scores (0–100), oldest first, ending with today.
        public var recentRecovery: [Double]
        /// Consecutive recent nights with HRV below the user's own baseline.
        public var hrvBelowBaselineStreak: Int
        public var load: LoadState
        /// Last week's session RPE (0–10) per session id, when rated.
        public var sessionRpe: [String: Double]
        /// Full weeks the plan has run.
        public var weeksActive: Int

        public init(adherence: [String: [Bool]] = [:], activeWeekdays: [Int: Int] = [:],
                    recentRecovery: [Double] = [], hrvBelowBaselineStreak: Int = 0,
                    load: LoadState = .unknown, sessionRpe: [String: Double] = [:], weeksActive: Int = 0) {
            self.adherence = adherence
            self.activeWeekdays = activeWeekdays
            self.recentRecovery = recentRecovery
            self.hrvBelowBaselineStreak = hrvBelowBaselineStreak
            self.load = load
            self.sessionRpe = sessionRpe
            self.weeksActive = weeksActive
        }
    }

    public enum Reason: Codable, Equatable, Sendable {
        case missedTwice
        case lowRecovery(days: Int)
        case lowHRV(days: Int)
        case loadHigh
        case steady(weeks: Int)
    }

    public enum Change: Codable, Equatable, Sendable {
        case move(sessionId: String, from: Int, to: Int)
        case shorten(sessionId: String, from: Int, to: Int)
        case lengthen(sessionId: String, from: Int, to: Int)
        /// One more working set on every line of the session's program.
        case addSet(sessionId: String, programId: String)

        public var sessionId: String {
            switch self {
            case .move(let id, _, _), .shorten(let id, _, _), .lengthen(let id, _, _), .addSet(let id, _): return id
            }
        }
    }

    public struct Item: Codable, Equatable, Sendable {
        public let change: Change
        public let reason: Reason
        public init(change: Change, reason: Reason) {
            self.change = change
            self.reason = reason
        }
    }

    public struct Revision: Codable, Equatable, Sendable {
        /// The week the revision is for (local yyyy-MM-dd of its first day).
        public let weekKey: String
        public let items: [Item]
        public init(weekKey: String, items: [Item]) {
            self.weekKey = weekKey
            self.items = items
        }
    }

    /// Recovery below this is "low" (the red band).
    public static let lowRecovery = 34.0
    public static let fatigueDays = 3
    public static let hrvStreakDays = 4
    public static let steadyWeeks = 3
    public static let maxProgressions = 2

    public static func review(sessions: [PlanSession], signals: Signals, weekKey: String) -> Revision? {
        var items: [Item] = []
        var touched = Set<String>()
        // Longest first; on a tie a cardio session before a strength one (routines adapt on their own at
        // start), then the earlier weekday.
        let byLength = sessions.sorted {
            ($0.minutes, $0.programId == nil ? 1 : 0, $1.weekday) > ($1.minutes, $1.programId == nil ? 1 : 0, $0.weekday)
        }

        // 1. Fatigue: shorten the longest session.
        let lowDays = trailingCount(signals.recentRecovery) { $0 < lowRecovery }
        let fatigueReason: Reason? = lowDays >= fatigueDays ? .lowRecovery(days: lowDays)
            : signals.hrvBelowBaselineStreak >= hrvStreakDays ? .lowHRV(days: signals.hrvBelowBaselineStreak) : nil
        if let reason = fatigueReason, let longest = byLength.first(where: { $0.minutes >= 20 }) {
            let to = max(15, round5(Double(longest.minutes) * 2 / 3))
            if to < longest.minutes {
                items.append(Item(change: .shorten(sessionId: longest.id, from: longest.minutes, to: to), reason: reason))
                touched.insert(longest.id)
            }
        } else if signals.load == .high, let longest = byLength.first(where: { $0.minutes >= 20 }) {
            let to = max(15, round5(Double(longest.minutes) * 0.8))
            if to < longest.minutes {
                items.append(Item(change: .shorten(sessionId: longest.id, from: longest.minutes, to: to), reason: .loadHigh))
                touched.insert(longest.id)
            }
        }

        // 2. Missed twice in a row: move to the weekday the user actually trains on.
        var planned = Set(sessions.map(\.weekday))
        for session in sessions.sorted(by: { $0.weekday < $1.weekday }) where !touched.contains(session.id) {
            let flags = signals.adherence[session.id] ?? []
            guard flags.count >= 2, !flags[flags.count - 1], !flags[flags.count - 2] else { continue }
            let candidates = signals.activeWeekdays
                .filter { $0.value > 0 && !planned.contains($0.key) && (1...7).contains($0.key) }
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            guard let to = candidates.first?.key else { continue }
            items.append(Item(change: .move(sessionId: session.id, from: session.weekday, to: to), reason: .missedTwice))
            touched.insert(session.id)
            planned.insert(to)
        }

        // 3. Steady weeks, rested body, load not high: progress a little.
        if fatigueReason == nil, signals.load != .high, signals.weeksActive >= steadyWeeks {
            var progressed = 0
            for session in sessions.sorted(by: { $0.weekday < $1.weekday }) where !touched.contains(session.id) {
                guard progressed < maxProgressions else { break }
                let flags = signals.adherence[session.id] ?? []
                guard flags.count >= steadyWeeks, flags.suffix(steadyWeeks).allSatisfy({ $0 }) else { continue }
                if let rpe = signals.sessionRpe[session.id], rpe > 8 { continue }
                let reason = Reason.steady(weeks: steadyWeeks)
                if let programId = session.programId {
                    items.append(Item(change: .addSet(sessionId: session.id, programId: programId), reason: reason))
                } else {
                    let to = min(120, max(session.minutes + 5, round5(Double(session.minutes) * 1.1)))
                    guard to > session.minutes else { continue }
                    items.append(Item(change: .lengthen(sessionId: session.id, from: session.minutes, to: to), reason: reason))
                }
                touched.insert(session.id)
                progressed += 1
            }
        }

        return items.isEmpty ? nil : Revision(weekKey: weekKey, items: items)
    }

    /// The schedule after `items`. `addSet` changes the program, not the schedule.
    public static func apply(_ items: [Item], to sessions: [PlanSession]) -> [PlanSession] {
        sessions.map { session in
            var s = session
            for item in items where item.change.sessionId == s.id {
                switch item.change {
                case .move(_, _, let to): s.weekday = to
                case .shorten(_, _, let to), .lengthen(_, _, let to): s.minutes = to
                case .addSet: break
                }
            }
            return s
        }
    }

    static func round5(_ minutes: Double) -> Int { Int((minutes / 5).rounded()) * 5 }

    static func trailingCount(_ values: [Double], where predicate: (Double) -> Bool) -> Int {
        var n = 0
        for v in values.reversed() {
            guard predicate(v) else { break }
            n += 1
        }
        return n
    }
}
