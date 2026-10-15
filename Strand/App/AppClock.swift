import Foundation
import StrandAnalytics

/// App-side reader for the Clock format setting. `AppLanguage.activeLocale` builds `language_REGION`, whose
/// region carries its default hour cycle but not the user's 24-Hour Time override (that lives on
/// `Locale.autoupdatingCurrent`), so the override is applied here.
enum AppClock {
    /// The stored preference, defaulting to `.system` so an upgrade changes nobody's display.
    static var preference: ClockFormatPreference {
        ClockFormatPreference.from(stored: UserDefaults.standard.string(forKey: ClockFormatPreference.defaultsKey))
    }

    /// What the device is set to, read from `autoupdatingCurrent` because that is the locale the 24-Hour
    /// Time switch modifies. Memoised: `DateFormatter.dateFormat(fromTemplate:)` builds an ICU pattern
    /// generator, which is expensive per access.
    static var systemUses24Hour: Bool {
        // Arm the invalidator here, not in hourMinuteFormatter(): some call sites reach AppClock only through
        // `formattingLocale`, and every path lands here. Touched before the lock (registration does not need it).
        _ = localeObserver
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cachedSystem24 { return cachedSystem24 }
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0,
                                                locale: Locale.autoupdatingCurrent) ?? "H"
        let v = !template.contains("a")
        cachedSystem24 = v
        return v
    }

    static var uses24Hour: Bool {
        ClockFormat.uses24Hour(preference: preference, systemUses24Hour: systemUses24Hour)
    }

    /// Memoised: `AppLanguage.activeLocale` constructs a `Locale` per access.
    static var activeLocale: Locale {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cachedActiveLocale { return cachedActiveLocale }
        let l = AppLanguage.activeLocale
        cachedActiveLocale = l
        return l
    }

    /// The locale for any time-rendering `DateFormatter`. Carries an explicit hour cycle, so the setting
    /// also reaches formatters that never name a pattern.
    static var formattingLocale: Locale {
        let id = ClockFormat.hourCycleLocaleIdentifier(base: activeLocale.identifier,
                                                       uses24Hour: uses24Hour)
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cachedFormattingLocale, cachedFormattingLocaleID == id { return cachedFormattingLocale }
        let l = Locale(identifier: id)
        cachedFormattingLocale = l
        cachedFormattingLocaleID = id
        return l
    }

    private static var cached: (template: String, locale: String, formatter: DateFormatter)?
    private static var cachedSystem24: Bool?
    private static var cachedActiveLocale: Locale?
    private static var cachedFormattingLocale: Locale?
    private static var cachedFormattingLocaleID: String?
    /// One lock for every cache here. Accessors never nest: NSLock is not recursive.
    private static let cacheLock = NSLock()

    /// Drop every memo, on a setting change and when the system clock or locale changes (`systemUses24Hour`
    /// can flip with no write of ours).
    static func invalidate() {
        cacheLock.lock()
        cached = nil
        cachedSystem24 = nil
        cachedActiveLocale = nil
        cachedFormattingLocale = nil
        cachedFormattingLocaleID = nil
        cacheLock.unlock()
    }

    /// Registers once on first use (a `static let` is lazy and thread-safe). Device locale and the 24-hour
    /// switch can change without a write from us.
    private static let localeObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil
    ) { _ in AppClock.invalidate() }

    /// Wall-clock time at minute precision, honouring the setting.
    static func hourMinuteFormatter() -> DateFormatter {
        let template = ClockFormat.hourMinuteTemplate(uses24Hour: uses24Hour)
        let locale = activeLocale
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached, cached.template == template, cached.locale == locale.identifier {
            return cached.formatter
        }
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        cached = (template, locale.identifier, f)
        return f
    }

    static func hourMinute(_ date: Date) -> String { hourMinuteFormatter().string(from: date) }

    static func hourMinute(unix ts: Int) -> String {
        hourMinute(Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
