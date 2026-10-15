import Foundation

// MindfulPractice.swift - which sessions count as mindfulness practice, and the weekly figures built
// from them (minutes this week against the user's own normal week, streak, practice days).
//
// Sources: mind-body workouts (yoga, meditation, pilates, stretching, tai chi, breathwork), the app's
// own breathing / meditation sessions, and Apple Health mindful sessions. One stretch of time is
// counted once: overlapping sessions from different sources are merged, keeping the richer source.
// Pure and database-free; the caller hands in plain sessions and a calendar.

public enum MindfulPractice {

    // MARK: - Session

    public enum Kind: String, Sendable, CaseIterable {
        case meditation, yoga, breathing, pilates, stretching, taiChi
    }

    /// Where a session came from, in merge precedence order (lower raw value wins an overlap).
    public enum Source: Int, Sendable, Comparable {
        /// The app's own breathing exercise or meditation timer.
        case app = 0
        /// A workout row (strap-detected, manual or imported).
        case workout = 1
        /// An Apple Health mindful session (no sport, no heart data of its own).
        case appleHealth = 2

        public static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Session: Equatable, Sendable {
        public let startTs: Int
        public let endTs: Int
        public let kind: Kind
        public let source: Source

        public init(startTs: Int, endTs: Int, kind: Kind, source: Source) {
            self.startTs = startTs
            self.endTs = max(startTs, endTs)
            self.kind = kind
            self.source = source
        }

        public var seconds: Int { endTs - startTs }
        public var minutes: Double { Double(seconds) / 60 }
    }

    /// Sessions shorter than this are taps, not practice.
    public static let minSessionSeconds = 60

    /// The mind-body kind a workout sport name maps to, or nil for every other sport. Accepts the app's
    /// catalogue names ("Yoga"), Apple Health activity names ("MindAndBody", "taiChi") and imports.
    public static func kind(forSport sport: String) -> Kind? {
        let key = sport.lowercased().filter { $0.isLetter }
        if key.contains("meditat") || key.contains("mindandbody") || key.contains("mindful") { return .meditation }
        if key.contains("yoga") { return .yoga }
        if key.contains("breath") || key.contains("atem") { return .breathing }
        if key.contains("pilates") { return .pilates }
        if key.contains("taichi") || key.contains("qigong") { return .taiChi }
        if key.contains("stretch") || key.contains("flexibility") || key.contains("dehn") { return .stretching }
        return nil
    }

    /// Drops too-short sessions and merges overlaps: when two sessions share time, the one from the
    /// higher-precedence source survives and absorbs the other's span. Result is oldest first.
    public static func merge(_ sessions: [Session]) -> [Session] {
        let sorted = sessions
            .filter { $0.seconds >= minSessionSeconds }
            .sorted { ($0.startTs, $0.source) < ($1.startTs, $1.source) }
        var out: [Session] = []
        for s in sorted {
            guard let last = out.last, s.startTs < last.endTs else { out.append(s); continue }
            let keep = s.source < last.source ? s : last
            out[out.count - 1] = Session(startTs: min(last.startTs, s.startTs), endTs: max(last.endTs, s.endTs),
                                         kind: keep.kind, source: keep.source)
        }
        return out
    }

    // MARK: - Weekly summary

    /// Rolling 7-day windows, so "this week" is always a full week and compares fairly with past ones.
    public struct Summary: Equatable, Sendable {
        /// Practice minutes in the last 7 days.
        public let minutesThisWeek: Double
        /// Days with practice in the last 7 days.
        public let practiceDaysThisWeek: Int
        public let sessionsThisWeek: Int
        /// Minutes of each earlier 7-day window, newest first, back to the first session ever seen.
        public let pastWeekMinutes: [Double]
        /// Practice days of each earlier 7-day window, newest first.
        public let pastWeekDays: [Int]
        /// Consecutive days with practice, ending today (or yesterday when today has none yet).
        public let streakDays: Int

        public init(minutesThisWeek: Double, practiceDaysThisWeek: Int, sessionsThisWeek: Int,
                    pastWeekMinutes: [Double], pastWeekDays: [Int], streakDays: Int) {
            self.minutesThisWeek = minutesThisWeek
            self.practiceDaysThisWeek = practiceDaysThisWeek
            self.sessionsThisWeek = sessionsThisWeek
            self.pastWeekMinutes = pastWeekMinutes
            self.pastWeekDays = pastWeekDays
            self.streakDays = streakDays
        }

        /// Median minutes of the earlier weeks, nil until `minWeeksForNormal` exist.
        public var typicalWeekMinutes: Double? {
            pastWeekMinutes.count >= MindfulPractice.minWeeksForNormal ? MindfulPractice.median(pastWeekMinutes) : nil
        }
        /// Interquartile range of the earlier weeks' minutes (the user's normal week).
        public var typicalMinutesRange: ClosedRange<Double>? { MindfulPractice.typicalRange(pastWeekMinutes) }
        public var typicalDaysRange: ClosedRange<Double>? { MindfulPractice.typicalRange(pastWeekDays.map(Double.init)) }
    }

    /// Earlier weeks needed before a "normal week" is claimed.
    public static let minWeeksForNormal = 3
    /// How many earlier weeks the normal week looks back over.
    public static let normalWindowWeeks = 8

    /// Builds the weekly figures from already-merged sessions. A window only counts as history once it
    /// ends after the first session ever seen, so a new user is not compared to empty weeks.
    public static func summary(_ sessions: [Session], now: Date, calendar: Calendar) -> Summary {
        let nowTs = Int(now.timeIntervalSince1970)
        let past = sessions.filter { $0.startTs <= nowTs }
        let week = 7 * 86_400
        func window(_ from: Int, _ to: Int) -> (minutes: Double, days: Int, count: Int) {
            let xs = past.filter { $0.startTs > from && $0.startTs <= to }
            return (xs.reduce(0) { $0 + $1.minutes }, Set(xs.map { dayKey($0.startTs, calendar) }).count, xs.count)
        }
        let current = window(nowTs - week, nowTs)
        var minutes: [Double] = [], days: [Int] = []
        if let first = past.map(\.startTs).min() {
            for back in 1...normalWindowWeeks {
                let to = nowTs - back * week
                guard to > first else { break }
                let w = window(to - week, to)
                minutes.append(w.minutes)
                days.append(w.days)
            }
        }
        return Summary(minutesThisWeek: current.minutes, practiceDaysThisWeek: current.days,
                       sessionsThisWeek: current.count, pastWeekMinutes: minutes, pastWeekDays: days,
                       streakDays: streak(past, now: now, calendar: calendar))
    }

    /// Lower to upper quartile, nil below `minWeeksForNormal` values.
    public static func typicalRange(_ xs: [Double]) -> ClosedRange<Double>? {
        guard xs.count >= minWeeksForNormal else { return nil }
        let s = xs.sorted()
        func q(_ p: Double) -> Double {
            let pos = p * Double(s.count - 1)
            let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
            return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
        }
        return q(0.25)...q(0.75)
    }

    /// Consecutive practice days ending today; a day without practice yet today does not break a streak
    /// that ran through yesterday.
    public static func streak(_ sessions: [Session], now: Date, calendar: Calendar) -> Int {
        let days = Set(sessions.map { dayKey($0.startTs, calendar) })
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(dayKey(cursor, calendar)) {
            guard let y = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = y
        }
        var count = 0
        while days.contains(dayKey(cursor, calendar)) {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    /// "YYYY-MM-DD" of the local day a timestamp falls on.
    public static func dayKey(_ ts: Int, _ calendar: Calendar) -> String {
        dayKey(Date(timeIntervalSince1970: TimeInterval(ts)), calendar)
    }

    public static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }
}
