import Foundation

/// The language Zoop uses for app-owned copy. Only English and German ship; "System" follows a German
/// phone and uses English otherwise. Units and clock preferences stay separate.
/// Apple picks a bundle's localization at launch, so `apply(_:)` writes the `AppleLanguages` override and
/// Settings asks the user to reopen Zoop; a live SwiftUI `locale` alone would leave `String(localized:)`
/// and `StrandDesign.module` strings in the old language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case german = "de"

    static let storageKey = "zoop.appLanguage"

    var id: String { rawValue }

    /// Autonyms on purpose, so the picker stays understandable from an unfamiliar language.
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

    /// Fold a stored tag from an older build back to System; English, German and System pass through.
    static func canonicalizeStoredValue(_ raw: String) -> String {
        let resolved = resolve(raw)
        if resolved == .system && raw != AppLanguage.system.rawValue {
            return AppLanguage.system.rawValue
        }
        return resolved.rawValue
    }

    /// The bundle language to force: English or German, or German only when the phone itself is German.
    static func resolvedTag(for raw: String, systemLanguageTag: String) -> String {
        switch resolve(raw) {
        case .english: return "en"
        case .german:  return "de"
        case .system:
            let sub = systemLanguageTag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            return sub == "de" ? "de" : "en"
        }
    }

    /// Read the phone language from the global domain so our own `AppleLanguages` override does not echo back.
    static func deviceLanguageTag() -> String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return (global?["AppleLanguages"] as? [String])?.first ?? "en"
    }

    /// Persist the bundle-language override; takes effect next launch.
    static func apply(_ raw: String,
                      defaults: UserDefaults = .standard,
                      systemLanguageTag: String? = nil) {
        let system = systemLanguageTag ?? deviceLanguageTag()
        defaults.set([resolvedTag(for: raw, systemLanguageTag: system)], forKey: "AppleLanguages")
    }

    /// Rewrite a legacy stored tag, then write the override for the next launch.
    static func installAtLaunch(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: storageKey) ?? system.rawValue
        let canonical = canonicalizeStoredValue(stored)
        if canonical != stored {
            defaults.set(canonical, forKey: storageKey)
        }
        apply(canonical, defaults: defaults)
    }

    /// Locale for SwiftUI format styles in the language the running bundles chose (follows `Bundle`, not the
    /// pending picker value).
    static var activeLocale: Locale {
        let bundleLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        let language = bundleLanguage.split(separator: "-").first.map(String.init) ?? bundleLanguage
        let words = (language == "de") ? "de" : "en"
        // Keep the device's regional conventions (clock, date order, separators) with the app language's words,
        // e.g. English on a German device is `en_DE`.
        if let region = Locale.autoupdatingCurrent.region?.identifier {
            return Locale(identifier: "\(words)_\(region)")
        }
        return Locale(identifier: words)
    }
}
