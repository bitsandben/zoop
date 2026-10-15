import Foundation

// MARK: - Intermittent fasting
//
// Fasting windows are typed in by the user; the strap measures none of it. Everything here is
// arithmetic on those timestamps, so nothing may claim a metabolic state: phase names are rough
// time-since-last-meal bands and ring markers are clock marks. Glucose, ketones and insulin are
// not measured, and copy built from these values must say so.

/// A fasting plan: how many hours of the day are fasted. The eating window is the rest of the day.
public struct FastingPlan: Hashable, Sendable, Identifiable {
    /// Stable storage key ("16:8", "omad", "custom"); persisted with every session, never renamed.
    public let id: String
    public let fastingHours: Double

    public var eatingHours: Double { max(0, 24 - fastingHours) }
    public var goal: TimeInterval { fastingHours * 3600 }
    public var isCustom: Bool { id == Self.customID }

    public static let customID = "custom"

    public static let twelve = FastingPlan(id: "12:12", fastingHours: 12)
    public static let fourteen = FastingPlan(id: "14:10", fastingHours: 14)
    public static let sixteen = FastingPlan(id: "16:8", fastingHours: 16)
    public static let eighteen = FastingPlan(id: "18:6", fastingHours: 18)
    public static let twenty = FastingPlan(id: "20:4", fastingHours: 20)
    public static let omad = FastingPlan(id: "omad", fastingHours: 23)

    public static let presets: [FastingPlan] = [twelve, fourteen, sixteen, eighteen, twenty, omad]
    public static let defaultPlan = sixteen

    /// Custom goals in whole hours. The upper bound keeps a typo (e.g. 160 h) from becoming a goal the
    /// streak can never meet.
    public static let customHours: ClosedRange<Int> = 10...48

    public static func custom(hours: Int) -> FastingPlan {
        let h = min(max(hours, customHours.lowerBound), customHours.upperBound)
        return FastingPlan(id: customID, fastingHours: Double(h))
    }

    /// The plan behind a stored id. Unknown ids fall back to the default so a newer build's session still renders.
    public static func resolve(id: String, customHours: Int) -> FastingPlan {
        if id == customID { return custom(hours: customHours) }
        return presets.first { $0.id == id } ?? defaultPlan
    }
}

/// One logged fast; `end == nil` while running. `goal` is the plan's goal when the fast started, so
/// changing the plan later doesn't rewrite whether an old fast met its goal.
public struct FastingInterval: Equatable, Sendable, Identifiable {
    public let id: String
    public let start: Date
    public let end: Date?
    public let goal: TimeInterval

    public init(id: String, start: Date, end: Date?, goal: TimeInterval) {
        self.id = id
        self.start = start
        self.end = end
        self.goal = goal
    }

    public var isActive: Bool { end == nil }

    public func duration(now: Date) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }

    /// Only a finished fast can have met its goal; a running one is pending, not a miss.
    public var metGoal: Bool {
        guard let end else { return false }
        return end.timeIntervalSince(start) >= goal
    }
}

/// Rough elapsed-time bands, NOT measured metabolic stages.
public enum FastingPhase: Int, CaseIterable, Sendable {
    case afterMeal, fasted, long, extended

    /// Lower bound of each band in hours. ~4 h is the usual postprandial window; 12 h and 18 h match
    /// the ring's marks. Physiology varies widely, so the screen labels these as guides.
    public var startsAtHours: Double {
        switch self {
        case .afterMeal: return 0
        case .fasted: return 4
        case .long: return 12
        case .extended: return 18
        }
    }

    public static func at(elapsed: TimeInterval) -> FastingPhase {
        let hours = elapsed / 3600
        return allCases.last { hours >= $0.startsAtHours } ?? .afterMeal
    }

    public var next: FastingPhase? { FastingPhase(rawValue: rawValue + 1) }
}

/// Live state of a running fast.
public struct FastingStatus: Equatable, Sendable {
    public let elapsed: TimeInterval
    public let goal: TimeInterval
    /// 0…1 of the goal; capped at 1 so the ring never wraps.
    public let progress: Double
    public let remaining: TimeInterval
    public let goalReached: Bool
    public let goalDate: Date
    public let phase: FastingPhase
}

/// Why a start/end pair cannot be saved. The sheet shows one line per case.
public enum FastingValidation: Equatable, Sendable {
    case ok
    case endBeforeStart
    case inFuture
    case tooLong
    case overlaps
}

public enum FastingEngine {

    /// Clock marks drawn on the ring (hours). Time markers only.
    public static let markerHours: [Double] = [12, 16, 18, 20]

    /// Longest fast the log accepts; a week-long "fast" is almost always a forgotten stop button.
    public static let maxDuration: TimeInterval = 72 * 3600

    /// Tolerance for "now": the picker and the clock can differ by a few seconds.
    static let futureTolerance: TimeInterval = 60

    public static func status(of interval: FastingInterval, now: Date) -> FastingStatus {
        let elapsed = interval.duration(now: now)
        let goal = max(interval.goal, 1)
        return FastingStatus(
            elapsed: elapsed,
            goal: goal,
            progress: min(1, elapsed / goal),
            remaining: max(0, goal - elapsed),
            goalReached: elapsed >= goal,
            goalDate: interval.start.addingTimeInterval(goal),
            phase: FastingPhase.at(elapsed: elapsed)
        )
    }

    /// The ring's clock marks that fall strictly inside the goal, as fractions of it.
    public static func markerFractions(goal: TimeInterval) -> [(hours: Double, fraction: Double)] {
        guard goal > 0 else { return [] }
        return markerHours
            .filter { $0 * 3600 < goal }
            .map { ($0, $0 * 3600 / goal) }
    }

    /// Checks a start/end pair before saving. `others` are the other logged fasts; a running fast
    /// lasts until `now`.
    public static func validate(start: Date, end: Date?, now: Date,
                                others: [FastingInterval]) -> FastingValidation {
        let limit = now.addingTimeInterval(futureTolerance)
        if start > limit { return .inFuture }
        if let end {
            if end > limit { return .inFuture }
            if end <= start { return .endBeforeStart }
        }
        let stop = end ?? now
        if stop.timeIntervalSince(start) > maxDuration { return .tooLong }
        for other in others {
            let otherStop = other.end ?? now
            if start < otherStop && other.start < stop { return .overlaps }
        }
        return .ok
    }
}
