import Foundation

/// Heat grid from per-day values (e.g. daily active calories) for the Workouts 13-week heatmap.
/// Columns are Monday-first calendar weeks, rows are weekdays (0 = Mon); the last column is the
/// current week and its future days are empty. Calendar math is integer days_from_civil on
/// "yyyy-MM-dd" keys.
public enum ActivityHeatmap {

    public static let defaultWeeks = 13

    /// One grid cell. `day` is nil for a future pad cell, `value` nil for no data; `level` is 0 for
    /// no data, 1...4 for intensity.
    public struct Cell: Equatable, Sendable {
        public let day: String?
        public let value: Double?
        public let level: Int
        public init(day: String?, value: Double?, level: Int) {
            self.day = day
            self.value = value
            self.level = level
        }
    }

    /// `columns` is `weeks` arrays of 7 cells (row 0 = Monday). `scale` is the ramp denominator: the
    /// 90th-percentile active day floored at `rampFloorKcal`, so one huge session does not flatten the
    /// grid and a beginner's light days do not max out.
    public struct Grid: Equatable, Sendable {
        public let weeks: Int
        public let columns: [[Cell]]
        public let scale: Double
        /// Total of the window's active days (kcal).
        public let total: Double
        /// Consecutive-day activity streak ending today, or yesterday if nothing is logged yet today; 0 otherwise.
        public let streak: Int
        public init(weeks: Int, columns: [[Cell]], scale: Double, total: Double = 0, streak: Int = 0) {
            self.weeks = weeks
            self.columns = columns
            self.scale = scale
            self.total = total
            self.streak = streak
        }
        public var isEmpty: Bool { columns.allSatisfy { col in col.allSatisfy { $0.value == nil } } }
    }

    /// Ramp denominator floor (kcal).
    public static let rampFloorKcal = 250.0
    /// Percentile of active days the ramp scales to.
    public static let rampPercentile = 90.0

    /// - Parameters:
    ///   - values: "yyyy-MM-dd" to metric; missing days render as no-data cells.
    ///   - today: day key anchoring the rightmost column.
    ///   - weeks: number of week columns (default 13).
    public static func build(values: [String: Double], today: String, weeks: Int = defaultWeeks) -> Grid {
        guard let e = epochDay(today) else { return Grid(weeks: weeks, columns: [], scale: 0) }
        let cols = max(weeks, 1)
        let todayWeekday = mondayFirstWeekday(e)
        let currentMonday = e - todayWeekday
        let firstMonday = currentMonday - (cols - 1) * 7

        var active: [Double] = []   // present days with a positive value → the ramp's percentile basis
        var raw: [[Cell]] = []
        raw.reserveCapacity(cols)
        for c in 0..<cols {
            var col: [Cell] = []
            col.reserveCapacity(7)
            for r in 0..<7 {
                let d = firstMonday + c * 7 + r
                if d > e {
                    col.append(Cell(day: nil, value: nil, level: 0)) // future day in the current week
                } else {
                    let ds = civilDay(d)
                    let v = values[ds]
                    if let v, v > 0 { active.append(v) }
                    col.append(Cell(day: ds, value: v, level: 0))
                }
            }
            raw.append(col)
        }
        let scale = rampScale(active)
        // Shared StreakCalculator, so the grace for a not-yet-scored today matches the Settings streak.
        let keys = Array(values.keys)
        let streak = StreakCalculator.streaks(dayKeys: keys,
                                              qualified: keys.map { (values[$0] ?? 0) > 0 },
                                              today: today).current
        let leveled = raw.map { col in
            col.map { Cell(day: $0.day, value: $0.value, level: levelFor($0.value, scale)) }
        }
        return Grid(weeks: cols, columns: leveled, scale: scale, total: active.reduce(0, +), streak: streak)
    }

    /// Ramp denominator: nearest-rank 90th percentile of active days, floored at `rampFloorKcal`.
    static func rampScale(_ active: [Double]) -> Double {
        guard !active.isEmpty else { return rampFloorKcal }
        let sorted = active.sorted()
        let rank = max(1, Int(ceil(rampPercentile / 100.0 * Double(sorted.count))))
        let p90 = sorted[min(rank, sorted.count) - 1]
        return max(rampFloorKcal, p90)
    }

    /// 0 = no data; otherwise 1...4 by fraction of `scale` (a present-but-zero day is level 1).
    static func levelFor(_ value: Double?, _ scale: Double) -> Int {
        guard let value else { return 0 }
        if scale <= 0 { return 1 }
        return min(max(Int(ceil(value / scale * 4.0)), 1), 4)
    }

    /// Monday-first weekday (Mon = 0) of an epoch day; day 0 (1970-01-01) is a Thursday.
    static func mondayFirstWeekday(_ epochDay: Int) -> Int { ((epochDay + 3) % 7 + 7) % 7 }

    /// Parse "yyyy-MM-dd" to days since 1970-01-01 (proleptic Gregorian); nil if malformed.
    static func epochDay(_ ymd: String) -> Int? {
        let p = ymd.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              m >= 1, m <= 12, d >= 1, d <= 31 else { return nil }
        return daysFromCivil(y, m, d)
    }

    /// Inverse of `epochDay` (Hinnant civil_from_days).
    static func civilDay(_ epochDay: Int) -> String {
        let z = epochDay + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y0 = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = m <= 2 ? y0 + 1 : y0
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Days since 1970-01-01 from y/m/d fields (Hinnant days_from_civil).
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
