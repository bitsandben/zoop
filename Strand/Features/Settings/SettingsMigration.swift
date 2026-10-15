import Foundation
import StrandDesign

/// Retires the preferences whose Settings controls Zoop 2.0 removed (§3.9). With no control left, a value
/// stored by an older build could never be changed back, so each key is cleared and every reader falls to
/// its default, which is the look the design itself now owns:
///
/// | Key | Default after clearing |
/// |---|---|
/// | `zoop.liquidTodayEnabled` | on: the current Today (the classic one is going, WP-07) |
/// | `zoop.bottomBarAutoHide` | off: the tab bar stays put |
/// | `zoop.showDayCycleBackground` | on: Classic draws the sky; Pastel & Nature never does |
/// | `zoop.skyBehindCards` | on: only visible through see-through cards, which are gone |
/// | `zoop.cardOpacityPercent` | 100: solid cards |
/// | `zoop.backgroundImageEnabled` | off: the custom photo backdrop is not drawn |
/// | `settingsAdvancedOpen` | gone: the Advanced disclosure became a page |
///
/// Runs on every launch rather than once: restoring an older preferences snapshot
/// (`LocalSettingsArchive`) could bring a retired value back, and clearing absent keys costs nothing.
enum SettingsMigration {
    static let retiredKeys = [
        "zoop.liquidTodayEnabled",
        "zoop.bottomBarAutoHide",
        SceneBackgroundPrefs.enabledKey,
        SkyBehindCardsPrefs.enabledKey,
        CardAppearancePrefs.opacityKey,
        BackgroundImagePrefs.enabledKey,
        "settingsAdvancedOpen",
    ]

    /// Call before anything reads these keys (`BackgroundImageStore` caches its flag at first use).
    static func run(defaults: UserDefaults = .standard) {
        for key in retiredKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }
}
