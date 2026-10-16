import Foundation

// MARK: - Fasting timeline and stats: logged eating windows, per-day bars, averages and adherence

/// A finished eating window between two logged fasts: `previousID` ended at `opens` (first meal),
/// `nextID` started at `closes` (last meal).
public struct LoggedEatingWindow: Equatable, Sendable, Identifiable {
    public let previousID: String
    public let nextID: String
    public let opens: Date
    public let closes: Date

    public var id: String { previousID + ">" + nextID }
    public var length: TimeInterval { closes.timeIntervalSince(opens) }
}

public enum FastingSegmentKind: Equatable, Sendable { case fasting, eating }

/// One bar piece inside a day, as fractions of that day (0 = midnight, 1 = next midnight).
public struct FastingTimelineSegment: Equatable, Sendable {
    public let kind: FastingSegmentKind
    public let startFraction: Double
    public let endFraction: Double
    /// Still running at `now` (the running fast or the open window).
    public let isLive: Bool
}

public struct FastingTimelineDay: Equatable, Sendable {
    public let dayStart: Date
    public let segments: [FastingTimelineSegment]
}

/// Last-N-days figures for the stats grid. Nil values mean "nothing finished in the window yet".
public struct FastingStats: Equatable, Sendable {
    public let averageFast: TimeInterval?
    public let longestFast: TimeInterval?
    public let averageEatingWindow: TimeInterval?
    /// Goal-met days over considered days (the consistency rule), 0…1.
    public let adherence: Double?
    public let fastsCounted: Int
}

public extension FastingCycle {

    /// A gap between fasts longer than this is untracked time (a missed log), not an eating window.
    static let maxEatingWindow: TimeInterval = 24 * 3600

    /// Eating windows between consecutive finished fasts, oldest first.
    static func eatingWindows(_ intervals: [FastingInterval]) -> [LoggedEatingWindow] {
        let sorted = intervals.sorted { $0.start < $1.start }
        return zip(sorted, sorted.dropFirst()).compactMap { a, b in
            guard let end = a.end else { return nil }
            let gap = b.start.timeIntervalSince(end)
            guard gap > 0, gap <= maxEatingWindow else { return nil }
            return LoggedEatingWindow(previousID: a.id, nextID: b.id, opens: end, closes: b.start)
        }
    }

    /// The last `days` calendar days ending today, oldest first, each with its fasting and eating
    /// pieces clipped to the day. `open` is the live eating window (from `state`), drawn up to now.
    static func timeline(_ intervals: [FastingInterval], open: EatingWindow?, now: Date,
                         days: Int = 7, calendar: Calendar) -> [FastingTimelineDay] {
        var spans: [(FastingSegmentKind, Date, Date, Bool)] = intervals.map {
            (.fasting, $0.start, $0.end ?? now, $0.isActive)
        }
        spans += eatingWindows(intervals).map { (.eating, $0.opens, $0.closes, false) }
        if let open { spans.append((.eating, open.opens, min(now, open.closes), true)) }

        let today = calendar.startOfDay(for: now)
        return (0..<max(days, 1)).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let length = next.timeIntervalSince(day)
            let segments = spans.compactMap { kind, start, end, live -> FastingTimelineSegment? in
                let s = max(start, day), e = min(end, next)
                guard e > s else { return nil }
                return FastingTimelineSegment(kind: kind,
                                              startFraction: s.timeIntervalSince(day) / length,
                                              endFraction: e.timeIntervalSince(day) / length,
                                              isLive: live)
            }
            .sorted { $0.startFraction < $1.startFraction }
            return FastingTimelineDay(dayStart: day, segments: segments)
        }
    }

    /// Averages over finished fasts that ended in the last `days` days, plus plan adherence.
    static func stats(_ intervals: [FastingInterval], now: Date, days: Int = 30,
                      calendar: Calendar) -> FastingStats {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
        let recent = intervals.filter { ($0.end.map { $0 >= cutoff && $0 <= now }) ?? false }
        let lengths = recent.map { $0.duration(now: now) }
        let windows = eatingWindows(intervals).filter { $0.closes >= cutoff }.map(\.length)
        let c = FastingEngine.consistency(intervals, now: now, days: days, calendar: calendar)
        return FastingStats(
            averageFast: lengths.isEmpty ? nil : lengths.reduce(0, +) / Double(lengths.count),
            longestFast: lengths.max(),
            averageEatingWindow: windows.isEmpty ? nil : windows.reduce(0, +) / Double(windows.count),
            adherence: c.consideredDays > 0 ? Double(c.metDays) / Double(c.consideredDays) : nil,
            fastsCounted: lengths.count)
    }

    /// Validates moving an eating window: `opens` becomes the previous fast's end and `closes` the next
    /// fast's start. Both fasts are checked with the same rules as a direct edit.
    static func validateWindow(opens: Date, closes: Date, previous: FastingInterval, next: FastingInterval,
                               now: Date, others: [FastingInterval]) -> FastingValidation {
        guard closes > opens else { return .endBeforeStart }
        let rest = others.filter { $0.id != previous.id && $0.id != next.id }
        let prev = FastingEngine.validate(start: previous.start, end: opens, now: now, others: rest)
        guard prev == .ok else { return prev }
        return FastingEngine.validate(start: closes, end: next.end, now: now, others: rest)
    }
}
