import SwiftUI
import StrandDesign
import StrandAnalytics

/// Display units. Display-only: Zoop stores SI, so switching never rewrites history.
struct SettingsUnitsGroup: View {
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    /// Empty = follow the body-measurement choice.
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    /// Empty = follow the body-measurement choice.
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    /// #1846: lead skin temperature with °C/°F or with the move from your baseline.
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""
    /// #268: Zoop's 0–100 axis or WHOOP's 0–21 Day Strain axis; the stored value is always 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    /// Shows the resolved distance unit even while it still follows the body choice.
    private var distanceBinding: Binding<String> {
        Binding(
            get: {
                UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                          override: distanceSystemRaw).rawValue
            },
            set: { distanceSystemRaw = $0 })
    }

    var body: some View {
        SettingsGroup(title: "Units", footer: Text("zoop.settings.units.footer")) {
            SettingsMenuRow(label: "Body measurements", selection: $unitSystemRaw, isFirst: true) {
                Text("Metric").tag(UnitSystem.metric.rawValue)
                Text("Imperial").tag(UnitSystem.imperial.rawValue)
            }
            SettingsMenuRow(label: "Exercise distance & pace", selection: distanceBinding) {
                Text("Kilometres").tag(UnitSystem.metric.rawValue)
                Text("Miles").tag(UnitSystem.imperial.rawValue)
            }
            SettingsMenuRow(label: "Temperature", selection: $temperatureRaw) {
                Text("Follow body").tag("")
                Text(verbatim: "°C").tag(TemperatureUnit.celsius.rawValue)
                Text(verbatim: "°F").tag(TemperatureUnit.fahrenheit.rawValue)
            }
            SettingsMenuRow(label: "Skin temperature", selection: $skinTempDisplayRaw) {
                Text("Temperature").tag("")
                Text("vs baseline").tag(SkinTempDisplay.Kind.deviation.rawValue)
            }
            SettingsMenuRow(label: "Effort scale", selection: $effortScaleRaw) {
                Text(verbatim: "0–100").tag(EffortScale.hundred.rawValue)
                Text(verbatim: "0–21").tag(EffortScale.whoop.rawValue)
            }
        }
    }
}
