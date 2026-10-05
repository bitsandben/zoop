import XCTest
@testable import Strand

final class AppLanguageTests: XCTestCase {
    func testUnknownStoredValueFallsBackToSystem() {
        XCTAssertEqual(AppLanguage.resolve("unsupported"), .system)
    }

    func testLegacyCatalogTagsFallBackToSystem() {
        for tag in ["zh", "it", "pl", "es", "fr", "pt-PT"] {
            XCTAssertEqual(AppLanguage.resolve(tag), .system, tag)
        }
    }

    func testOnlyEnglishAndGermanAreCases() {
        XCTAssertEqual(Set(AppLanguage.allCases), [.system, .english, .german])
    }

    func testResolvedTagIsEnglishOrGermanOnly() {
        XCTAssertEqual(AppLanguage.resolvedTag(for: "en", systemLanguageTag: "de-DE"), "en")
        XCTAssertEqual(AppLanguage.resolvedTag(for: "de", systemLanguageTag: "en"), "de")
        XCTAssertEqual(AppLanguage.resolvedTag(for: "system", systemLanguageTag: "de-DE"), "de")
        XCTAssertEqual(AppLanguage.resolvedTag(for: "system", systemLanguageTag: "de_AT"), "de")
        XCTAssertEqual(AppLanguage.resolvedTag(for: "system", systemLanguageTag: "fr-FR"), "en")
        XCTAssertEqual(AppLanguage.resolvedTag(for: "zh", systemLanguageTag: "de"), "de")
        XCTAssertEqual(AppLanguage.resolvedTag(for: "es", systemLanguageTag: "es-MX"), "en")
    }

    func testCanonicalizeRewritesLegacyTagsAndKeepsExplicitChoices() {
        XCTAssertEqual(AppLanguage.canonicalizeStoredValue("es"), AppLanguage.system.rawValue)
        XCTAssertEqual(AppLanguage.canonicalizeStoredValue("en"), "en")
        XCTAssertEqual(AppLanguage.canonicalizeStoredValue("de"), "de")
        XCTAssertEqual(AppLanguage.canonicalizeStoredValue("system"), "system")
    }

    func testApplyWritesOnlyEnglishOrGerman() throws {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppLanguage.apply(AppLanguage.german.rawValue, defaults: defaults, systemLanguageTag: "fr-FR")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["de"])

        AppLanguage.apply(AppLanguage.system.rawValue, defaults: defaults, systemLanguageTag: "fr-CA")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])

        AppLanguage.apply("es", defaults: defaults, systemLanguageTag: "de-AT")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["de"])
    }

    func testInstallAtLaunchFoldsALegacyTag() throws {
        let suiteName = "AppLanguageTests.install.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("fr", forKey: AppLanguage.storageKey)
        let stored = defaults.string(forKey: AppLanguage.storageKey) ?? ""
        let canonical = AppLanguage.canonicalizeStoredValue(stored)
        if canonical != stored {
            defaults.set(canonical, forKey: AppLanguage.storageKey)
        }
        AppLanguage.apply(canonical, defaults: defaults, systemLanguageTag: "en-US")

        XCTAssertEqual(defaults.string(forKey: AppLanguage.storageKey), "system")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
    }
}
