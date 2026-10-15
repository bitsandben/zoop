import Foundation

// MARK: - Sleep Regularity Index (Phillips et al., 2017)
//
// SRI = −100 + 200 · P(same state at t and t + 24 h), over 5-minute epochs of noon-to-noon days. 100
// means identical sleep timing every day, 0 means timing is random. A day only counts when it holds at
// least three hours of recorded sleep: a night the strap was off would otherwise read as "awake all
// night" and drag the index down for a reason that has nothing to do with the sleeper.

public enum SleepRegularity {

    public struct Result: Equatable, Sendable {
        /// −100…100; in practice 40–95 for adults.
        public let index: Double
        /// Consecutive valid day pairs the index was computed over.
        public let dayPairs: Int
        /// Mean sleep midpoint in minutes after local midnight (0..<1440).
        public let midpointMin: Double
    }

    public static let epochSeconds = 300
    public static let epochsPerDay = 86_400 / epochSeconds
    /// Fewer pairs than this leaves the index dominated by a single odd night.
    public static let minDayPairs = 5
    public static let minSleepPerDayMin = 180.0
    public static let windowDays = 14

    /// Sleep windows as `(start, end)` unix seconds; `endDay` is the local day the window ends on.
    public static func compute(windows: [(start: Int, end: Int)], endDay: Date, days: Int = windowDays,
                        calendar: Calendar = .current) -> Result? {
        let grid = paint(windows: windows, endDay: endDay, days: days, calendar: calendar)
        return index(grid)
    }

    /// The index for each of the last `count` days, oldest first, each over its own trailing window.
    /// nil entries are days without enough data, so the history fold treats them as missing.
    public static func trailingSeries(windows: [(start: Int, end: Int)], endDay: Date, count: Int,
                               days: Int = windowDays, calendar: Calendar = .current) -> [(day: Date, index: Double?)] {
        let grid = paint(windows: windows, endDay: endDay, days: days + count - 1, calendar: calendar)
        return (0..<count).map { i in
            let slice = Array(grid[i..<(i + days)])
            let day = calendar.date(byAdding: .day, value: i - count + 1, to: endDay) ?? endDay
            return (day, index(slice)?.index)
        }
    }

    // MARK: Internals

    /// One row per noon-to-noon day (oldest first) of asleep flags, or nil for a day without enough sleep.
    private static func paint(windows: [(start: Int, end: Int)], endDay: Date, days: Int,
                              calendar: Calendar) -> [[Bool]?] {
        let lastNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: endDay) ?? endDay
        return (0..<days).map { i -> [Bool]? in
            let dayNoon = calendar.date(byAdding: .day, value: i - days + 1, to: lastNoon) ?? lastNoon
            let end = Int(dayNoon.timeIntervalSince1970)
            let start = end - 86_400
            var row = [Bool](repeating: false, count: epochsPerDay)
            var asleep = 0
            for w in windows where w.end > start && w.start < end {
                let a = max(0, (max(w.start, start) - start) / epochSeconds)
                let b = min(epochsPerDay, (min(w.end, end) - start + epochSeconds - 1) / epochSeconds)
                guard b > a else { continue }
                for e in a..<b where !row[e] { row[e] = true; asleep += 1 }
            }
            return Double(asleep * epochSeconds) / 60 >= minSleepPerDayMin ? row : nil
        }
    }

    private static func index(_ grid: [[Bool]?]) -> Result? {
        var same = 0, total = 0, pairs = 0
        for (a, b) in zip(grid, grid.dropFirst()) {
            guard let a, let b else { continue }
            pairs += 1
            for e in 0..<epochsPerDay {
                total += 1
                if a[e] == b[e] { same += 1 }
            }
        }
        guard pairs >= minDayPairs, total > 0 else { return nil }
        let midpoints = grid.compactMap { row -> Double? in
            guard let row else { return nil }
            let idx = row.indices.filter { row[$0] }
            guard !idx.isEmpty else { return nil }
            return Double(idx.reduce(0, +)) / Double(idx.count)
        }
        let meanEpoch = midpoints.reduce(0, +) / Double(max(midpoints.count, 1))
        // Rows start at noon, so the night is contiguous and a plain mean is safe; shift back to midnight.
        let midpoint = ((meanEpoch + 0.5) * Double(epochSeconds) / 60 + 720).truncatingRemainder(dividingBy: 1_440)
        return Result(index: -100 + 200 * Double(same) / Double(total), dayPairs: pairs, midpointMin: midpoint)
    }
}
