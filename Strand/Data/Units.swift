import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Unit system preference
//
// Everything is stored in SI (km, kg, cm, °C); units are a display-only layer. Body measurements and
// exercise distance have separate Metric/Imperial choices, plus a SEPARATE temperature override.

enum UnitSystem: String, CaseIterable, Identifiable {
    case metric
    case imperial
    var id: String { rawValue }

    var temperatureMatching: TemperatureUnit { self == .imperial ? .fahrenheit : .celsius }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit
    var id: String { rawValue }
}

/// Effort is stored 0-100; this cosmetic toggle shows the same value on WHOOP's 0-21 Day Strain axis (#268).
enum EffortScale: String, CaseIterable, Identifiable {
    case hundred
    case whoop
    var id: String { rawValue }
}

/// Trends tab chart style (line + area vs bars). Display-only; the plotted data is identical.
enum TrendChartStyle: String, CaseIterable, Identifiable {
    case line
    case bar
    var id: String { rawValue }
    var label: String { self == .bar ? "Bars" : "Line" }
}

/// Which sleep window the nightly HRV is measured over (#141). `whole` averages RMSSD across the whole
/// night; WHOOP and others sample the last slow-wave window, which reads lower. NOT display-only: it
/// changes the computed avgHrv, so a switch re-scores and re-baselines.
enum HrvWindow: String, CaseIterable, Identifiable {
    case whole
    /// RMSSD over DEEP (slow-wave) sleep windows only, the window WHOOP samples.
    ///
    /// "Comparable to WHOOP" describes the METHOD, not the accuracy: the deep windows come from Zoop's own
    /// stager, which `Tools/SleepPSG` measures at 18.94 % predicted deep vs 13.76 % truth (+5.18 pp bias,
    /// four-class kappa 0.356). An over-inclusive deep window pulls this value toward the whole-night mean.
    /// So this stays opt-in and `whole` stays the default (#1008); re-run the benchmark before changing it.
    case deep
    var id: String { rawValue }
    var label: String { self == .deep ? "Deep sleep" : "Whole night" }
}

enum UnitPrefs {
    /// The original combined preference, now owning body measurements. Keeping its key preserves existing
    /// kg/cm or lb/ft-in choices without a migration.
    static let systemKey = "units.system"
    static let distanceSystemKey = "units.distance"
    static let temperatureKey = "units.temperature"

    /// Which skin-temp number the cards lead with (#1846): absent/`""` = a temperature, or
    /// `SkinTempDisplay.Kind.deviation.rawValue` for the signed move from baseline. Display-only.
    static let skinTempDisplayKey = "units.skinTempDisplay"
    static let effortScaleKey = "effort.scale"

    static let trendChartStyleKey = "trend.chart.style"

    /// Nightly-HRV window (#141): an `HrvWindow` rawValue; unset/unknown resolves to `.whole`. NOT
    /// display-only: the engine reads it and a Settings switch re-scores.
    static let hrvWindowKey = "hrv.window"

    /// Display factor for the Effort scale: the stored 0-100 value times this renders on the chosen axis
    /// (1.0 for 0-100, 0.21 for 0-21).
    static func currentEffortDisplayFactor() -> Double {
        let raw = UserDefaults.standard.string(forKey: effortScaleKey) ?? ""
        return raw == EffortScale.whoop.rawValue ? 0.21 : 1.0
    }

    /// The persisted choices as `MetricUnit` display systems, for readout builders outside a view that cannot
    /// hold `@AppStorage`. Values stay SI; only the shown unit changes.
    static func currentMetricMassSystem() -> MetricUnit.System {
        let raw = UserDefaults.standard.string(forKey: systemKey) ?? ""
        return UnitSystem(rawValue: raw) == .imperial ? .imperial : .metric
    }

    static func currentMetricTemperatureSystem() -> MetricUnit.System {
        let defaults = UserDefaults.standard
        let system = UnitSystem(rawValue: defaults.string(forKey: systemKey) ?? "") ?? .metric
        let unit = resolveTemperature(system: system, override: defaults.string(forKey: temperatureKey) ?? "")
        return unit == .fahrenheit ? .imperial : .metric
    }

    static func resolveTemperature(system: UnitSystem, override raw: String) -> TemperatureUnit {
        if let explicit = TemperatureUnit(rawValue: raw) { return explicit }
        return system.temperatureMatching
    }

    /// Resolves the exercise-distance system. An empty or unknown value follows the combined body preference
    /// until the user chooses independently.
    static func resolveDistance(system: UnitSystem, override raw: String) -> UnitSystem {
        UnitSystem(rawValue: raw) ?? system
    }

    static func resolveEffortScale(_ raw: String) -> EffortScale {
        EffortScale(rawValue: raw) ?? .hundred
    }
}

// MARK: - Pure conversion + formatting

enum UnitFormatter {

    // MARK: Factors (single source of truth — tests pin these exact numbers)

    static let milesPerKilometer = 0.621371
    static let poundsPerKilogram = 2.20462
    static let centimetersPerInch = 2.54

    // MARK: Distance (stored km)

    static func kmToMiles(_ km: Double) -> Double { km * milesPerKilometer }

    /// Formats a distance given in METRES (the stored workout unit). Metric: "1.2 km" / "850 m".
    /// Imperial: "0.7 mi" / "230 yd" for sub-mile distances.
    static func distanceFromMeters(_ meters: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:
            let km = meters / 1000.0
            return km >= 1 ? oneDecimal(km) + " km" : "\(Int(meters.rounded())) m"
        case .imperial:
            let miles = kmToMiles(meters / 1000.0)
            if miles >= 0.1 { return oneDecimal(miles) + " mi" }
            // Below ~160 m show yards rather than a "0.0 mi".
            let yards = meters * 1.09361
            return "\(Int(yards.rounded())) yd"
        }
    }

    /// Average pace for display: "m:ss /km" or "m:ss /mi"; "—" when undefined (nil or <= 0). `secPerKm` is
    /// what the GPS recorder publishes; matches the post-workout pace in the workout detail view (#1195).
    static func paceFromSecPerKm(_ secPerKm: Double?, system: UnitSystem) -> String {
        guard let secPerKm, secPerKm > 0 else { return "—" }
        let (secs, label): (Double, String) = system == .imperial
            ? (secPerKm / milesPerKilometer, "/mi")
            : (secPerKm, "/km")
        let s = Int(secs.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60)) \(label)"
    }

    static func distanceFromKilometers(_ km: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:   return oneDecimal(km) + " km"
        case .imperial: return oneDecimal(kmToMiles(km)) + " mi"
        }
    }

    static func distanceUnit(_ system: UnitSystem) -> String {
        system == .imperial ? "mi" : "km"
    }

    static func speedFromKilometersPerHour(_ kmh: Double?, system: UnitSystem) -> String? {
        guard let kmh, kmh.isFinite, kmh >= 0 else { return nil }
        switch system {
        case .metric:   return oneDecimal(kmh) + " km/h"
        case .imperial: return oneDecimal(kmToMiles(kmh)) + " mph"
        }
    }

    // MARK: Mass (stored kg)

    static func kgToPounds(_ kg: Double) -> Double { kg * poundsPerKilogram }

    static func massFromKilograms(_ kg: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:   return oneDecimal(kg) + " kg"
        case .imperial: return oneDecimal(kgToPounds(kg)) + " lb"
        }
    }

    static func massUnit(_ system: UnitSystem) -> String {
        system == .imperial ? "lb" : "kg"
    }

    // MARK: Height (stored cm)

    static func cmToInches(_ cm: Double) -> Double { cm / centimetersPerInch }

    static func cmToFeetInches(_ cm: Double) -> (feet: Int, inches: Int) {
        let totalInches = Int(cmToInches(cm).rounded())
        var feet = totalInches / 12
        var inches = totalInches % 12
        if inches == 12 { feet += 1; inches = 0 }   // rounding can push 11.5" → 12"
        return (feet, inches)
    }

    static func heightFromCentimeters(_ cm: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:
            return "\(Int(cm.rounded())) cm"
        case .imperial:
            let (ft, inch) = cmToFeetInches(cm)
            return "\(ft)′ \(inch)″"
        }
    }

    // MARK: Temperature (stored °C — absolute)

    static func celsiusToFahrenheit(_ c: Double) -> Double { c * 9.0 / 5.0 + 32.0 }

    static func temperatureFromCelsius(_ c: Double, unit: TemperatureUnit, decimals: Int = 1) -> String {
        switch unit {
        case .celsius:    return decimalString(c, decimals) + " °C"
        case .fahrenheit: return decimalString(celsiusToFahrenheit(c), decimals) + " °F"
        }
    }

    /// °C delta to °F delta: a DIFFERENCE scales by 9/5 with NO +32 offset. A Double so callers can do their
    /// own locale-aware formatting without inlining the 9/5.
    static func celsiusDeltaToFahrenheit(_ dc: Double) -> Double { dc * 9.0 / 5.0 }

    static func temperatureDeltaFromCelsius(_ dc: Double, unit: TemperatureUnit, decimals: Int = 1) -> String {
        switch unit {
        case .celsius:    return decimalString(dc, decimals) + " °C"
        case .fahrenheit: return decimalString(celsiusDeltaToFahrenheit(dc), decimals) + " °F"
        }
    }

    /// The skin-temperature phrase used by the illness-signal label: number and unit chip, ready for one `%@`.
    ///
    /// The field is BIMODAL (#111/#622): an imported night carries an ABSOLUTE wrist °C, a live one a signed
    /// DEVIATION, in one column, so the +32 offset applies to only one and the chip is "°F" or "Δ°F". Both
    /// come from `SkinTempDisplay`. The number is formatted here only to honour [locale] (a German reader
    /// must see "0,7"); pass nil for POSIX decimals.
    static func skinTempSignalPhrase(_ value: Double, fahrenheit: Bool, locale: Locale?) -> String {
        let kind = SkinTempDisplay.kind(of: value)
        let shown: Double
        if fahrenheit {
            shown = kind == .absolute ? celsiusToFahrenheit(value) : celsiusDeltaToFahrenheit(value)
        } else {
            shown = value
        }
        let number = String(format: kind == .absolute ? "%.1f" : "%+.1f", locale: locale, shown)
        return number + " " + SkinTempDisplay.unitSymbol(kind: kind, fahrenheit: fahrenheit)
    }

    static func temperatureUnit(_ unit: TemperatureUnit) -> String {
        unit == .fahrenheit ? "°F" : "°C"
    }

    // MARK: Effort scale (stored 0–100 — #268)

    /// Effort is stored 0-100 and WHOOP's Day Strain axis is 0-21. The import boundary rescales by 100/21
    /// (WhoopExportImporter.dayStrainToEffortScale), so the display inverse is x21/100.
    static let effortScaleFactor = 21.0 / 100.0

    static func effortValue(_ value: Double, scale: EffortScale) -> Double {
        scale == .whoop ? value * effortScaleFactor : value
    }

    /// Formats a stored 0-100 Effort value on the selected scale to one decimal. Every Effort read-out routes
    /// through this so the toggle reaches all of them.
    static func effortDisplay(_ value: Double, scale: EffortScale) -> String {
        oneDecimal(effortValue(value, scale: scale))
    }

    static func effortScaleMax(_ scale: EffortScale) -> String {
        scale == .whoop ? "21" : "100"
    }

    // MARK: Helpers

    private static func oneDecimal(_ v: Double) -> String { String(format: "%.1f", v) }

    private static func decimalString(_ v: Double, _ decimals: Int) -> String {
        decimals == 0 ? "\(Int(v.rounded()))" : String(format: "%.\(decimals)f", v)
    }
}
