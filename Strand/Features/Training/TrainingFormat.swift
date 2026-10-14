import Foundation
import WhoopStore

// MARK: - Training formatting
//
// Durations, distances, energy and dates for the Training screens, formatted for the app locale.
// One implementation here replaces the private copies the list and the detail each carried.

struct TrainingFormat {
    let distanceSystem: UnitSystem

    private var locale: Locale { AppLanguage.activeLocale }

    /// "1h 5m" / "45 Min." from seconds; an en dash when there is no duration.
    func duration(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "\u{2013}" }
        var style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .narrow,
                                              zeroValueUnits: .hide)
        style.locale = locale
        return Duration.seconds(Int64(seconds.rounded())).formatted(style)
    }

    /// Whole kilocalories with the locale's grouping, e.g. "1.234 kcal".
    func energy(_ kcal: Double) -> String {
        Int(kcal.rounded()).formatted(.number.locale(locale)) + "\u{00A0}kcal"
    }

    /// "10,4 km" / "850 m" (metric) or "6.5 mi" / "230 yd" (imperial); an en dash without a distance.
    func distance(meters: Double?) -> String {
        guard let meters, meters > 0 else { return "\u{2013}" }
        switch distanceSystem {
        case .metric:
            return meters >= 1000
                ? ZoopNumber.decimal(meters / 1000) + "\u{00A0}km"
                : Int(meters.rounded()).formatted(.number.locale(locale)) + "\u{00A0}m"
        case .imperial:
            let miles = UnitFormatter.kmToMiles(meters / 1000)
            // Below ~160 m a "0,0 mi" reads as nothing, so switch to yards.
            return miles >= 0.1
                ? ZoopNumber.decimal(miles) + "\u{00A0}mi"
                : Int((meters * 1.09361).rounded()).formatted(.number.locale(locale)) + "\u{00A0}yd"
        }
    }

    /// Sum of the positive distances; nil when no session carries one, so a total never reads "0 km"
    /// for a window of sports that simply have no distance.
    func totalDistance(of rows: [WorkoutRow]) -> String? {
        let positive = rows.compactMap(\.distanceM).filter { $0 > 0 }
        return positive.isEmpty ? nil : distance(meters: positive.reduce(0, +))
    }

    // MARK: Dates

    /// "8. Okt." / "Oct 8".
    func shortDate(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts))
            .formatted(Date.FormatStyle().day().month(.abbreviated).locale(locale))
    }

    /// "Mittwoch, 8. Oktober 2026".
    func longDate(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts))
            .formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).year().locale(locale))
    }

    /// "18:05–19:10" in the user's clock format; start only when the row carries no real end (#157).
    func timeRange(start: Int, end: Int) -> String {
        let formatter = AppClock.hourMinuteFormatter()
        func time(_ ts: Int) -> String { formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }
        return end > start ? "\(time(start))\u{2013}\(time(end))" : time(start)
    }
}
