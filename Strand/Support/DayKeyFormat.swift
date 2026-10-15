import Foundation

/// Shared "yyyy-MM-dd" day-key formatters (POSIX locale, Gregorian calendar), built once.
/// `local` follows the device zone (how `DailyMetric.day` is written); `utc` is for series banked at UTC.
enum DayKeyFormat {
    nonisolated static let local: DateFormatter = make(TimeZone.current)
    nonisolated static let utc: DateFormatter = make(TimeZone(identifier: "UTC")!)

    nonisolated private static func make(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
}
