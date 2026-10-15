import Foundation
import WhoopStore

// MARK: - SleepMark
//
// A user-tapped sleep boundary, recorded for the log only; it does NOT feed the sleep detector. Each
// mark is persisted into the long-format `metricSeries` store under key "sleep_mark" (natural key
// deviceId/day/key, single REAL value, so the type is encoded as 0 = bedtime, 1 = wake) and appended
// to the strap log. Pure and platform-free so it unit-tests without a UI.

/// One sleep boundary the user tapped.
enum SleepMarkType: Int, Equatable, Sendable {
    case bedtime = 0   // "Going to sleep"
    case wake = 1      // "I'm awake"

    /// The value persisted into the `sleep_mark` metric series (0 = bedtime, 1 = wake).
    var seriesValue: Double { Double(rawValue) }

    /// Decodes a persisted series value; rounds float drift and clamps unexpected values so a corrupt row never crashes.
    static func from(seriesValue: Double) -> SleepMarkType {
        Int(seriesValue.rounded()) == SleepMarkType.wake.rawValue ? .wake : .bedtime
    }

    /// Short word used in the toast and strap-log line.
    var word: String { self == .bedtime ? "bedtime" : "wake" }
}

/// A captured mark: a type plus the tap instant (unix MILLISECONDS). The calendar `day` is derived locally.
struct SleepMark: Equatable, Sendable {
    let type: SleepMarkType
    let tsMs: Int64

    init(type: SleepMarkType, tsMs: Int64) {
        self.type = type
        self.tsMs = tsMs
    }

    /// Captures a mark at `now` (injectable for tests).
    init(type: SleepMarkType, at now: Date = Date()) {
        self.type = type
        self.tsMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
    }

    /// The mark's local calendar day (yyyy-MM-dd), so it lands on the day the user tapped it.
    var dayKey: String { SleepMark.dayFormatter.string(from: date) }

    /// The tap instant as a `Date`.
    var date: Date { Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0) }

    /// Projects this mark into a `metricSeries` row (key "sleep_mark", value 0/1, local day). Upsert is
    /// idempotent, so a later same-day mark replaces the earlier value; the strap log keeps the sequence.
    var metricPoint: MetricPoint {
        MetricPoint(day: dayKey, key: SleepMark.seriesKey, value: type.seriesValue)
    }

    /// Reconstructs a mark from a persisted point. The point has no sub-day time, so the instant resolves
    /// to that day's local midnight; the type is exact.
    static func from(point: MetricPoint) -> SleepMark? {
        guard point.key == seriesKey,
              let day = dayFormatter.date(from: point.day) else { return nil }
        return SleepMark(type: .from(seriesValue: point.value),
                         tsMs: Int64((day.timeIntervalSince1970 * 1000).rounded()))
    }

    /// The strap-log line, e.g. "Sleep mark · bedtime (going to sleep) @ 23:42". Carries no PII.
    var logLine: String {
        let clock = SleepMark.clockFormatter.string(from: date)
        let phrase = type == .bedtime ? "going to sleep" : "awake"
        return "Sleep mark · \(type.word) (\(phrase)) @ \(clock)"
    }

    /// The toast shown after a tap, e.g. "Logged bedtime at 23:42." 
    var confirmation: String {
        let clock = SleepMark.clockFormatter.string(from: date)
        // Whole-phrase variants (not a stitched noun) so each localizes naturally.
        return type == .bedtime
            ? String(localized: "Logged bedtime at \(clock).")
            : String(localized: "Logged wake-up at \(clock).")
    }

    // MARK: - Constants / formatters

    /// The metric-series key all sleep marks share.
    static let seriesKey = "sleep_mark"

    /// yyyy-MM-dd in the device's local zone, matching how the rest of the store keys days.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Device-locale clock for the log line, following the 12-/24-hour setting. Routed through AppClock so
    /// the Clock format setting applies (#1821).
    private static var clockFormatter: DateFormatter { AppClock.hourMinuteFormatter() }
}
