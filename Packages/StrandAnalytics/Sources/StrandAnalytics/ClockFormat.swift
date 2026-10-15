import Foundation

/// Which clock the UI shows times in.
///
/// Building a locale from a region identifier discards the user's explicit "24-Hour Time" switch
/// (it lives on `Locale.autoupdatingCurrent`), so this preference lets readers choose (#1821).
public enum ClockFormatPreference: String, CaseIterable, Sendable {
    case system
    case twelveHour
    case twentyFourHour

    public static let defaultsKey = "clockFormatPreference"

    /// Unknown or absent stored values fall back to `.system`.
    public static func from(stored: String?) -> ClockFormatPreference {
        guard let stored, let parsed = ClockFormatPreference(rawValue: stored) else { return .system }
        return parsed
    }
}

public enum ClockFormat {
    /// Resolves the preference against what the device reports. `systemUses24Hour` is injected to keep
    /// this pure (Apple derives it from `Locale.autoupdatingCurrent`, which carries the 24-Hour switch).
    public static func uses24Hour(preference: ClockFormatPreference, systemUses24Hour: Bool) -> Bool {
        switch preference {
        case .system:         return systemUses24Hour
        case .twelveHour:     return false
        case .twentyFourHour: return true
        }
    }

    /// Literal wall-clock pattern at minute precision, for formatters driven by an explicit pattern.
    public static func hourMinutePattern(uses24Hour: Bool) -> String {
        uses24Hour ? "HH:mm" : "h:mm a"
    }

    /// A locale identifier carrying an explicit hour cycle (`h23`/`h12`), so formatters driven by
    /// `timeStyle` or a `j` template resolve the clock the reader chose instead of the region default.
    ///
    /// Keeps localized date order, separators and AM/PM wording. A malformed identifier silently falls
    /// back to the base locale, so `ClockFormatLocaleTests` asserts against a real `DateFormatter`.
    public static func hourCycleLocaleIdentifier(base: String, uses24Hour: Bool) -> String {
        "\(base)@hours=\(uses24Hour ? "h23" : "h12")"
    }

    /// Skeleton template for `setLocalizedDateFormatFromTemplate`: the locale still decides ordering and
    /// AM/PM wording while the H-vs-h choice stays ours. Not the `j` template, which defers the hour to the locale.
    public static func hourMinuteTemplate(uses24Hour: Bool) -> String {
        uses24Hour ? "Hmm" : "hmm"
    }
}
