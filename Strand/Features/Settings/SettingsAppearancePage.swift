import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import StrandDesign
import StrandAnalytics

/// Language, clock, motion and charts (the look itself lives in the Settings root), and the chart styles. The
/// day-cycle sky, transparent cards and the custom background left with Zoop 2.0; the design owns
/// the backdrop now (see `SettingsMigration`).
struct SettingsAppearancePage: View {
    /// Poses looping animations still and stops the tilt sensor without needing Low Power Mode.
    @AppStorage(QuietMotionPrefs.enabledKey) private var quietMotion = false
    /// Apple binds a bundle localization at launch, so this writes the AppleLanguages override and
    /// takes effect when Zoop is reopened.
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.system.rawValue
    @AppStorage(ClockFormatPreference.defaultsKey) private var clockFormatRaw = ClockFormatPreference.system.rawValue
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue
    @AppStorage(SleepChartStyle.storageKey) private var sleepChartStyleRaw = SleepChartStyle.classic.rawValue
    @AppStorage(UnitPrefs.trendChartStyleKey) private var trendChartStyleRaw = TrendChartStyle.line.rawValue
    /// Chrome only (links, buttons, selection); the data colours follow the chart style.
    @AppStorage(AccentColor.storageKey) private var accentRaw = AccentColor.mint.rawValue
    @AppStorage(AccentColor.customHexKey) private var accentCustomHex = AccentColor.defaultCustomHex

    var body: some View {
        SettingsPageScaffold(title: "zoop.settings.language.title") {
            languageGroup
            chartsGroup
            motionGroup
        }
    }

    private var motionGroup: some View {
        SettingsGroup {
            SettingsToggleRow(label: "Reduce motion in Zoop", isOn: $quietMotion,
                              note: "zoop.settings.appearance.motionNote", isFirst: true)
        }
    }

    private var languageGroup: some View {
        SettingsGroup(footer: Text("zoop.settings.appearance.languageNote")) {
            SettingsMenuRow(label: "Language", selection: $appLanguageRaw, isFirst: true) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language == .system ? String(localized: "System default") : language.autonym)
                        .tag(language.rawValue)
                }
            }
            .onChangeCompat(of: appLanguageRaw) { AppLanguage.apply($0) }
            // #1821: a display convention rather than a unit, and "System default" here means the device's
            // 24-Hour Time switch. No relaunch needed, but the resolved clock is memoised (#1829).
            SettingsMenuRow(label: "Clock", selection: $clockFormatRaw) {
                Text("System default").tag(ClockFormatPreference.system.rawValue)
                Text("12-hour").tag(ClockFormatPreference.twelveHour.rawValue)
                Text("24-hour").tag(ClockFormatPreference.twentyFourHour.rawValue)
            }
            .onChangeCompat(of: clockFormatRaw) { _ in AppClock.invalidate() }
        }
    }

    private var chartsGroup: some View {
        SettingsGroup(title: "zoop.settings.group.charts") {
            SettingsMenuRow(label: "Chart colours", selection: $chartStyleRaw, isFirst: true) {
                ForEach(ChartStyle.allCases) { style in Text(style.label).tag(style.rawValue) }
            }
            SettingsMenuRow(label: "Sleep chart", selection: $sleepChartStyleRaw) {
                ForEach(SleepChartStyle.allCases) { style in Text(style.label).tag(style.rawValue) }
            }
            SettingsMenuRow(label: "Trend charts", selection: $trendChartStyleRaw) {
                ForEach(TrendChartStyle.allCases) { style in Text(style.label).tag(style.rawValue) }
            }
            SettingsMenuRow(label: "Accent", selection: $accentRaw) {
                ForEach(AccentColor.allCases) { color in Text(color.label).tag(color.rawValue) }
            }
            if AccentColor.resolve(accentRaw) == .custom {
                SettingsRow(label: "Custom colour") {
                    ColorPicker("Custom colour", selection: customAccentBinding, supportsOpacity: false)
                        .labelsHidden()
                }
            }
        }
    }

    private var customAccentBinding: Binding<Color> {
        Binding(
            get: { Color(hex: accentCustomHex) },
            set: { accentCustomHex = $0.settingsHex ?? AccentColor.defaultCustomHex })
    }
}

private extension Color {
    /// sRGB `#RRGGBB` for persisting a `ColorPicker` choice; nil when the colour has no sRGB form.
    var settingsHex: String? {
        #if os(iOS)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #elseif os(macOS)
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = ns.redComponent, g = ns.greenComponent, b = ns.blueComponent
        #endif
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
