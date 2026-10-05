import Foundation

/// The language NOOP uses for app-owned copy. Region-specific measurement and clock preferences remain
/// separate: this changes words, not the user's unit-system choice or time zone.
///
/// Only English and German ship. "System" follows a German phone and uses English for every other
/// phone language, so a French or Chinese device does not surface a leftover translation.
///
/// Apple chooses a bundle's localization once, when the process launches. `apply(_:)` therefore writes
/// the standard `AppleLanguages` override and Settings tells the user to reopen NOOP. Applying only a
/// SwiftUI `locale` live would be incorrect: `Text` would switch immediately while `String(localized:)`
/// messages, notifications, and strings owned by `StrandDesign.module` stayed in the old language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case german = "de"

    static let storageKey = "zoop.appLanguage"

    var id: String { rawValue }

    /// Language names are autonyms on purpose, so the picker remains understandable while changing from
    /// an unfamiliar language. The system choice is localized at its call site.
    var autonym: String {
        switch self {
        case .system:  return ""
        case .english: return "English"
        case .german:  return "Deutsch"
        }
    }

    static func resolve(_ raw: String) -> AppLanguage {
        AppLanguage(rawValue: raw) ?? .system
    }

    /// Fold a stored tag from an older build (Spanish, French, …) back to System so the picker has a
    /// row to show. English, German, and System pass through unchanged.
    static func canonicalizeStoredValue(_ raw: String) -> String {
        let resolved = resolve(raw)
        if resolved == .system && raw != AppLanguage.system.rawValue {
            return AppLanguage.system.rawValue
        }
        return resolved.rawValue
    }

    /// The bundle language to force: explicit English or German, or German only when the phone itself
    /// is set to German. `systemLanguageTag` is the device tag, not the app override.
    static func resolvedTag(for raw: String, systemLanguageTag: String) -> String {
        switch resolve(raw) {
        case .english: return "en"
        case .german:  return "de"
        case .system:
            let sub = systemLanguageTag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            return sub == "de" ? "de" : "en"
        }
    }

    /// Read the phone language from the global domain so the app's own `AppleLanguages` override does
    /// not echo back as "the device is German" after we wrote that override last launch.
    static func deviceLanguageTag() -> String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return (global?["AppleLanguages"] as? [String])?.first ?? "en"
    }

    /// Persist the bundle-language override. Foundation observes it on the next process launch.
    static func apply(_ raw: String,
                      defaults: UserDefaults = .standard,
                      systemLanguageTag: String? = nil) {
        let system = systemLanguageTag ?? deviceLanguageTag()
        defaults.set([resolvedTag(for: raw, systemLanguageTag: system)], forKey: "AppleLanguages")
    }

    /// Rewrite a legacy stored tag, then write the English-or-German override for the next launch.
    static func installAtLaunch(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: storageKey) ?? system.rawValue
        let canonical = canonicalizeStoredValue(stored)
        if canonical != stored {
            defaults.set(canonical, forKey: storageKey)
        }
        apply(canonical, defaults: defaults)
    }

    /// Locale used by SwiftUI format styles for the language that the currently-running bundles chose.
    /// This deliberately follows `Bundle`, not the pending picker value, so changing the setting cannot
    /// produce a half-new/half-old UI before the requested reopen.
    static var activeLocale: Locale {
        let bundleLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        let language = bundleLanguage.split(separator: "-").first.map(String.init) ?? bundleLanguage
        let words = (language == "de") ? "de" : "en"
        // Preserve the device's regional conventions (24-hour clock, date order, decimal separator) while
        // taking month/weekday words from the app language: English on a German device becomes `en_DE`.
        if let region = Locale.autoupdatingCurrent.region?.identifier {
            return Locale(identifier: "\(words)_\(region)")
        }
        return Locale(identifier: words)
    }
}
