import XCTest
@testable import Strand

final class LocalSettingsArchiveTests: XCTestCase {
    func testEmptyDomainIsRestoredFromTheSnapshot() throws {
        let suite = "LocalSettingsArchiveTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-settings-\(UUID().uuidString).plist")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }

        defaults.set("de", forKey: "noop.appLanguage")
        defaults.set(true, forKey: "noop.onboarded")
        LocalSettingsArchive.snapshot(defaults: defaults, domain: suite, file: file)

        defaults.removePersistentDomain(forName: suite)
        XCTAssertTrue((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty)

        LocalSettingsArchive.restoreIfEmpty(defaults: defaults, domain: suite, file: file)
        XCTAssertEqual(defaults.string(forKey: "noop.appLanguage"), "de")
        XCTAssertEqual(defaults.bool(forKey: "noop.onboarded"), true)
    }

    func testALiveValueIsNotReplacedByAnOlderSnapshot() throws {
        let suite = "LocalSettingsArchiveTests.live.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-settings-\(UUID().uuidString).plist")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }

        defaults.set("de", forKey: "noop.appLanguage")
        LocalSettingsArchive.snapshot(defaults: defaults, domain: suite, file: file)
        defaults.set("en", forKey: "noop.appLanguage")

        LocalSettingsArchive.restoreIfEmpty(defaults: defaults, domain: suite, file: file)
        XCTAssertEqual(defaults.string(forKey: "noop.appLanguage"), "en")
    }

    func testAnEmptyDomainDoesNotEraseTheSnapshot() throws {
        let suite = "LocalSettingsArchiveTests.empty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-settings-\(UUID().uuidString).plist")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }

        defaults.set("de", forKey: "noop.appLanguage")
        LocalSettingsArchive.snapshot(defaults: defaults, domain: suite, file: file)
        let saved = try Data(contentsOf: file)

        defaults.removePersistentDomain(forName: suite)
        LocalSettingsArchive.snapshot(defaults: defaults, domain: suite, file: file)
        XCTAssertEqual(try Data(contentsOf: file), saved)
    }
}
