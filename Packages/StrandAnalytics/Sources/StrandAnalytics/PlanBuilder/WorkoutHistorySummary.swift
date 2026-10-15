import Foundation

/// The only history the plan builder may send to a coach provider: per-sport counts and typical
/// durations over a window, plus a weekly rate. No dates, no heart rate, no health data.
public struct WorkoutHistorySummary: Equatable, Sendable {

    public struct Sport: Equatable, Sendable {
        public let name: String
        public let count: Int
        /// Median session length in whole minutes; nil when no session carried a duration.
        public let typicalMinutes: Int?
    }

    public struct Session: Equatable, Sendable {
        public let sport: String
        public let durationS: Double?
        public let startTs: Int
        public init(sport: String, durationS: Double?, startTs: Int) {
            self.sport = sport
            self.durationS = durationS
            self.startTs = startTs
        }
    }

    public enum Level: String, Sendable, Equatable { case beginner, intermediate, advanced }

    public let windowDays: Int
    /// Most frequent first, at most `maxSports`.
    public let sports: [Sport]
    public let totalSessions: Int
    public let strengthSessions: Int

    public static let maxSports = 6

    public var sessionsPerWeek: Double { Double(totalSessions) / (Double(windowDays) / 7) }
    public var isEmpty: Bool { totalSessions == 0 }

    /// A starting guess for the experience question, from frequency and strength history alone.
    public var suggestedLevel: Level {
        let strengthPerWeek = Double(strengthSessions) / (Double(windowDays) / 7)
        if strengthPerWeek >= 2.5 && sessionsPerWeek >= 4 { return .advanced }
        if strengthPerWeek >= 1 || sessionsPerWeek >= 3 { return .intermediate }
        return .beginner
    }

    /// - Parameter isStrength: whether a sport name counts as structured strength training.
    public static func make(sessions: [Session], now: Date, windowDays: Int = 90,
                            isStrength: (String) -> Bool) -> WorkoutHistorySummary {
        let cutoff = Int(now.timeIntervalSince1970) - windowDays * 86_400
        let recent = sessions.filter { $0.startTs >= cutoff && $0.startTs <= Int(now.timeIntervalSince1970) }
        var bySport: [String: [Double]] = [:]
        var counts: [String: Int] = [:]
        for s in recent {
            counts[s.sport, default: 0] += 1
            if let d = s.durationS, d > 0 { bySport[s.sport, default: []].append(d) }
        }
        let sports = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(maxSports)
            .map { name, count in
                Sport(name: name, count: count, typicalMinutes: median(bySport[name] ?? []).map { Int(($0 / 60).rounded()) })
            }
        return WorkoutHistorySummary(windowDays: windowDays, sports: Array(sports),
                                     totalSessions: recent.count,
                                     strengthSessions: recent.filter { isStrength($0.sport) }.count)
    }

    /// One English line for the model, e.g. "Last 90 days: Walking 24× (~35 min), Pool swim 3× (~40 min);
    /// about 2.1 sessions per week; no structured strength training."
    public var promptLine: String {
        guard !isEmpty else { return "No workouts recorded in the last \(windowDays) days." }
        let list = sports.map { s in
            s.typicalMinutes.map { "\(s.name) \(s.count)× (~\($0) min)" } ?? "\(s.name) \(s.count)×"
        }.joined(separator: ", ")
        let rate = (sessionsPerWeek * 10).rounded() / 10
        let strength = strengthSessions == 0 ? "no structured strength training"
            : "\(strengthSessions) strength sessions"
        return "Last \(windowDays) days: \(list); about \(rate) sessions per week; \(strength)."
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
