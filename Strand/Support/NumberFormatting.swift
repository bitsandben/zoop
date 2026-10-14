import Foundation

/// Locale-aware number formatting for user-visible text (German shows "7,2 h", not "7.2 h").
/// Log, debug and export strings must keep `String(format:)` so they stay POSIX.
enum ZoopNumber {
    static func decimal(_ value: Double, digits: Int = 1, locale: Locale = AppLanguage.activeLocale) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    /// Always-signed decimal, e.g. "+1,5" / "-1,5".
    static func signed(_ value: Double, digits: Int = 1, locale: Locale = AppLanguage.activeLocale) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).sign(strategy: .always()).locale(locale))
    }

    /// A value already expressed in percent (12.5 -> "12,5%").
    static func percent(_ value: Double, digits: Int = 0, signed: Bool = false, locale: Locale = AppLanguage.activeLocale) -> String {
        let n = signed ? Self.signed(value, digits: digits, locale: locale) : decimal(value, digits: digits, locale: locale)
        return n + "%"
    }
}
