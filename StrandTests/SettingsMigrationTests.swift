import XCTest
@testable import Strand

/// Zoop 2.0 removed the Settings controls for these preferences, so a value stored by an older build
/// must not survive a launch: with no switch left, nobody could turn it back.
final class SettingsMigrationTests: XCTestCase {
    private let suite = "SettingsMigrationTests"

    func testRetiredKeysAreClearedAndOthersKept() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: "zoop.liquidTodayEnabled")
        defaults.set(true, forKey: "zoop.bottomBarAutoHide")
        defaults.set(false, forKey: "zoop.showDayCycleBackground")
        defaults.set(false, forKey: "zoop.skyBehindCards")
        defaults.set(40, forKey: "zoop.cardOpacityPercent")
        defaults.set(true, forKey: "zoop.backgroundImageEnabled")
        defaults.set(true, forKey: "settingsAdvancedOpen")
        defaults.set("pastel", forKey: "zoop.theme")

        SettingsMigration.run(defaults: defaults)

        for key in SettingsMigration.retiredKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should fall back to its default")
        }
        XCTAssertEqual(defaults.string(forKey: "zoop.theme"), "pastel", "Live preferences must be untouched")
    }

    func testRunningTwiceIsHarmless() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        SettingsMigration.run(defaults: defaults)
        SettingsMigration.run(defaults: defaults)
        XCTAssertTrue(SettingsMigration.retiredKeys.allSatisfy { defaults.object(forKey: $0) == nil })
    }
}
