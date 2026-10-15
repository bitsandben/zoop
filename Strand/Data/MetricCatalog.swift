import Foundation
import StrandAnalytics

/// One interrogable metric: how to fetch it (key+source), how to label/format it, and whether
/// higher is better (drives delta tinting). The Metric Explorer + Compare are built from this list.
struct MetricDescriptor: Identifiable, Hashable {
    let key: String
    let title: String
    let category: String
    let unit: String
    let source: String       // "my-whoop" or "apple-health"
    let icon: String
    let decimals: Int
    let higherIsBetter: Bool?
    /// A short plain-English one-liner (tile subtitle); only Charge / Effort / Rest carry one today.
    var description: String? = nil
    var id: String { source + ":" + key }

    /// Human label for the metric's source partition (catalog row caption / detail subtitle).
    var sourceLabel: String {
        switch source {
        case "apple-health": return "Apple Health"
        case "xiaomi-band":  return "Mi Band"
        case "nutrition-csv": return String(localized: "Nutrition")
        case "noop-mood":    return String(localized: "Mood")
        default:             return "Whoop"   // "my-whoop" + on-device computed sources
        }
    }

    /// True for the Effort metric: stored 0-100, the effort-scale toggle converts the DISPLAYED value
    /// and unit onto WHOOP's 0-21 axis. The only value-converting metric in the catalog.
    private var isEffort: Bool { key == "strain" }

    /// skin_temp is stored either as an absolute temperature (WHOOP export) or a signed DEVIATION from
    /// baseline (live pipeline); `VitalBands.isAbsoluteSkinTemp(v)` (v >= 20 C) tells them apart per
    /// value. A deviation converts to F by x9/5 with NO +32 offset; an absolute reading uses the full
    /// conversion. Key-based, like `isEffort`.
    private var isSkinTemp: Bool { key == "skin_temp" }

    func format(_ v: Double) -> String {
        let n = decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    /// Effort-aware plain format: Effort's stored 0-100 shows on the selected scale; every other
    /// metric falls through to `format`. Callers without an effort scale get `.hundred`.
    func format(_ v: Double, effortScale: EffortScale) -> String {
        guard isEffort else { return format(v) }
        let n = UnitFormatter.effortDisplay(v, scale: effortScale)
        return "\(n) \(displayUnit(effortScale: effortScale))"
    }

    /// Unit-aware format: weight/lean_mass (kg) and skin_temp (C) convert and relabel via
    /// `UnitFormatter`, Effort follows its own 0-100 / 0-21 scale; everything else uses plain `format`.
    func format(_ v: Double, system: UnitSystem, temperature: TemperatureUnit,
                effortScale: EffortScale = .hundred) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massFromKilograms(v, system: system)
        case "°C":
            // skin_temp is bimodal (absolute vs deviation); `SkinTempDisplay` keeps deviations as signed "Δ°C" / "Δ°F".
            if isSkinTemp {
                return SkinTempDisplay.format(v, fahrenheit: temperature == .fahrenheit, decimals: decimals)
            }
            return UnitFormatter.temperatureFromCelsius(v, unit: temperature, decimals: decimals)
        default:    return isEffort ? format(v, effortScale: effortScale) : format(v)
        }
    }

    /// Like `format`, but for a DIFFERENCE between two values. Temperature deltas scale by 9/5 with no
    /// +32 offset; mass/distance by their plain factor; Effort rescales 0-100 to 0-21. The caller
    /// supplies the magnitude (sign is rendered separately).
    func formatDelta(_ v: Double, system: UnitSystem, temperature: TemperatureUnit,
                     effortScale: EffortScale = .hundred) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massFromKilograms(v, system: system)
        case "°C":  return UnitFormatter.temperatureDeltaFromCelsius(v, unit: temperature, decimals: decimals)
        default:
            guard isEffort else { return format(v) }
            // A delta on the 0–100 axis rescales by the same ×21/100 factor (the offset-free `effortValue`).
            let n = UnitFormatter.effortDisplay(v, scale: effortScale)
            return "\(n) \(displayUnit(effortScale: effortScale))"
        }
    }

    /// The unit label as displayed for the active system; only convertible units change.
    func displayUnit(system: UnitSystem, temperature: TemperatureUnit,
                     effortScale: EffortScale = .hundred) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massUnit(system)
        case "°C":  return UnitFormatter.temperatureUnit(temperature)
        default:    return isEffort ? displayUnit(effortScale: effortScale) : unit
        }
    }

    /// The Effort unit label on the selected scale ("/100" or "/21"); other metrics keep their stored label.
    func displayUnit(effortScale: EffortScale) -> String {
        guard isEffort else { return unit }
        return "/" + UnitFormatter.effortScaleMax(effortScale)
    }
}

/// Canonical catalog: the WHOOP "Trend View" metrics plus Apple Health body metrics. Keys match
/// what the importers write into metricSeries.
enum MetricCatalog {
    static let categories = ["Heart", "Charge", "Rest", "Effort", "Health", "Nutrition", "Mind"]

    /// The three scores' names: iOS uses Recovery, Strain and Sleep, as Home labels the rings.
    private static func scoreName(_ mac: String.LocalizationValue, ios: String.LocalizationValue) -> String {
        #if os(iOS)
        String(localized: ios)
        #else
        String(localized: mac)
        #endif
    }

    static let all: [MetricDescriptor] = [
        // ── Heart
        d("avg_hr", String(localized: "Average Heart Rate"), "Heart", "bpm", "my-whoop", "heart", 0, nil),
        d("max_hr", String(localized: "Max Heart Rate"), "Heart", "bpm", "my-whoop", "bolt.heart", 0, nil),
        d("energy_kcal", String(localized: "Calories"), "Heart", "kcal", "my-whoop", "flame", 0, nil),
        d("vo2max", String(localized: "VO₂ Max"), "Heart", "", "apple-health", "lungs.fill", 1, true),
        d("fitness_age", String(localized: "Fitness Age"), "Heart", "yrs", "my-whoop", "figure.run", 0, false),
        d("vo2max_est", String(localized: "VO₂ Max (estimated)"), "Heart", "", "my-whoop", "lungs", 1, true),
        d("vitality", String(localized: "Vitality"), "Heart", "", "my-whoop", "sparkles", 0, true),
        d("body_age", String(localized: "Body Age"), "Heart", "yrs", "my-whoop", "figure.stand", 0, false),

        // ── Charge (was Recovery)
        d("recovery", Self.scoreName("Charge", ios: "Recovery"), "Charge", "%", "my-whoop", "heart.circle", 0, true,
          String(localized: "How recovered you are, led by HRV versus your personal baseline.")),
        d("hrv", String(localized: "Heart Rate Variability"), "Charge", "ms", "my-whoop", "waveform.path.ecg", 0, true),
        d("rhr", String(localized: "Resting Heart Rate"), "Charge", "bpm", "my-whoop", "heart", 0, false),
        d("resp_rate", String(localized: "Respiratory Rate"), "Charge", "rpm", "my-whoop", "lungs", 1, nil),
        d("spo2", String(localized: "Blood Oxygen"), "Charge", "%", "my-whoop", "drop", 0, true),
        d("skin_temp", String(localized: "Skin Temperature"), "Charge", "°C", "my-whoop", "thermometer", 1, nil),

        // ── Rest (was Sleep)
        d("sleep_performance", Self.scoreName("Rest", ios: "Sleep"), "Rest", "%", "my-whoop", "moon.stars", 0, true,
          String(localized: "How restorative your sleep was: duration, efficiency, deep+REM, timing.")),
        d("in_bed_min", String(localized: "Time in Bed"), "Rest", "min", "my-whoop", "bed.double", 0, nil),
        d("sleep_total_min", String(localized: "Asleep Time"), "Rest", "min", "my-whoop", "moon.zzz", 0, true),
        d("hours_vs_needed_pct", String(localized: "Hours vs Needed"), "Rest", "%", "my-whoop", "gauge.medium", 0, true),
        d("sleep_consistency", String(localized: "Sleep Consistency"), "Rest", "%", "my-whoop", "calendar", 0, true),
        d("restorative_pct", String(localized: "Restorative Sleep"), "Rest", "%", "my-whoop", "sparkles", 0, true),
        d("restorative_min", String(localized: "Restorative Sleep"), "Rest", "min", "my-whoop", "sparkles", 0, true),
        d("sleep_efficiency", String(localized: "Sleep Efficiency"), "Rest", "%", "my-whoop", "bed.double.fill", 0, true),
        d("sleep_deep_min", String(localized: "Deep (SWS) Sleep"), "Rest", "min", "my-whoop", "moon.fill", 0, true),
        d("sleep_rem_min", String(localized: "REM Sleep"), "Rest", "min", "my-whoop", "moon.haze", 0, true),
        d("sleep_light_min", String(localized: "Light Sleep"), "Rest", "min", "my-whoop", "moon", 0, nil),
        d("sleep_need_min", String(localized: "Sleep Need"), "Rest", "min", "my-whoop", "gauge", 0, nil),
        d("sleep_debt_min", String(localized: "Sleep Debt"), "Rest", "min", "my-whoop", "exclamationmark.circle", 0, false),

        // ── Effort (was Strain)
        d("strain", Self.scoreName("Effort", ios: "Strain"), "Effort", "/100", "my-whoop", "flame", 1, nil,
          String(localized: "Cardiovascular load for the day, on a 0-100 scale (was 0-21).")),
        d("steps", String(localized: "Steps"), "Effort", "", "apple-health", "figure.walk", 0, true),
        // Declared AFTER apple-health on purpose: bare-key `first { key == "steps" }` resolvers keep their
        // apple-health default. The Today card/tile route here explicitly by source (`.metricSourced` /
        // `todayStepsMetric`).
        d("steps", String(localized: "Steps"), "Effort", "steps", "my-whoop", "figure.walk", 0, true),
        // On-device steps ESTIMATE for a WHOOP 4.0 (no BLE step count): daily motion volume scaled by a
        // personal calibration, under the computed "-zoop" source. Labelled "(estimated)" to stay distinct
        // from the measured "steps" above.
        d("steps_est", String(localized: "Steps (estimated)"), "Effort", "steps", "my-whoop", "figure.walk.motion", 0, true,
          String(localized: "Estimated from your WHOOP's motion, calibrated to your phone. Not a measured step count.")),
        d("hr_zones13_min", String(localized: "HR Zones 1-3"), "Effort", "min", "my-whoop", "heart", 0, nil),
        d("hr_zones45_min", String(localized: "HR Zones 4-5"), "Effort", "min", "my-whoop", "heart.fill", 0, nil),
        d("hr_zones_all_min", String(localized: "HR Zones (All)"), "Effort", "min", "my-whoop", "heart.text.square", 0, nil),
        d("strength_min", String(localized: "Strength Activity Time"), "Effort", "min", "my-whoop", "dumbbell", 0, nil),
        d("active_kcal", String(localized: "Active Energy"), "Effort", "kcal", "apple-health", "flame.fill", 0, nil),

        // ── Health / Body
        d("weight", String(localized: "Weight"), "Health", "kg", "apple-health", "scalemass", 1, nil),
        d("body_fat", String(localized: "Body Fat"), "Health", "%", "apple-health", "percent", 1, false),
        d("lean_mass", String(localized: "Lean Body Mass"), "Health", "kg", "apple-health", "figure.arms.open", 1, true),
        d("bmi", "BMI", "Health", "", "apple-health", "figure", 1, nil),
        d("stress", String(localized: "Day Stress"), "Health", "/3", "my-whoop", "gauge.with.dots.needle.50percent", 1, false),

        // ── Nutrition (imported from a food-tracker CSV: calories-in alongside calories-out)
        d("calories_in", String(localized: "Calories In"), "Nutrition", "kcal", "nutrition-csv", "fork.knife", 0, nil),
        d("protein_g", String(localized: "Protein"), "Nutrition", "g", "nutrition-csv", "p.circle", 0, nil),
        d("carbs_g", String(localized: "Carbs"), "Nutrition", "g", "nutrition-csv", "c.circle", 0, nil),
        d("fat_g", String(localized: "Fat"), "Nutrition", "g", "nutrition-csv", "f.circle", 0, nil),

        // ── Mind (daily mood check-in, 1–5; non-clinical self-tracking)
        d("mood", String(localized: "Mood"), "Mind", "/5", "noop-mood", "face.smiling", 0, true),

        // ── Mi Band (imported from Mi Fitness). A distinct `source` keeps these comparable against the
        //    WHOOP/Apple versions rather than colliding.
        d("avg_hr", String(localized: "Average Heart Rate"), "Heart", "bpm", "xiaomi-band", "heart", 0, nil),
        d("max_hr", String(localized: "Max Heart Rate"), "Heart", "bpm", "xiaomi-band", "bolt.heart", 0, nil),
        d("energy_kcal", String(localized: "Calories"), "Heart", "kcal", "xiaomi-band", "flame", 0, nil),
        d("vitality", String(localized: "Vitality"), "Heart", "", "xiaomi-band", "sparkles", 0, true),
        d("rhr", String(localized: "Resting Heart Rate"), "Charge", "bpm", "xiaomi-band", "heart", 0, false),
        d("spo2", String(localized: "Blood Oxygen"), "Charge", "%", "xiaomi-band", "drop", 0, true),
        d("sleep_total_min", String(localized: "Asleep Time"), "Rest", "min", "xiaomi-band", "moon.zzz", 0, true),
        d("sleep_deep_min", String(localized: "Deep (SWS) Sleep"), "Rest", "min", "xiaomi-band", "moon.fill", 0, true),
        d("sleep_rem_min", String(localized: "REM Sleep"), "Rest", "min", "xiaomi-band", "moon.haze", 0, true),
        d("sleep_light_min", String(localized: "Light Sleep"), "Rest", "min", "xiaomi-band", "moon", 0, nil),
        d("sleep_score", String(localized: "Sleep Score"), "Rest", "", "xiaomi-band", "moon.stars", 0, true),
        d("steps", String(localized: "Steps"), "Effort", "", "xiaomi-band", "figure.walk", 0, true),
        d("intensity_min", String(localized: "Intensity Minutes"), "Effort", "min", "xiaomi-band", "figure.run", 0, true),
        d("stress", String(localized: "Stress"), "Health", "/100", "xiaomi-band", "gauge.with.dots.needle.50percent", 0, false),
    ]

    static func inCategory(_ c: String) -> [MetricDescriptor] { all.filter { $0.category == c } }

    /// Explicit fused view for the rolling-average tile; not a replacement for source-specific entries.
    static let combinedStepsSource = "noop-combined-steps"

    static func metric(key: String, source: String) -> MetricDescriptor? {
        if key == "steps", source == combinedStepsSource {
            return d("steps", String(localized: "Steps"), "Effort", "", source, "figure.walk", 0, true)
        }
        return all.first { $0.key == key && $0.source == source }
    }

    /// The source the Today steps tile taps through to, matching its displayed value: measured WHOOP
    /// 5.0 / MG count, else imported Apple Health, else the WHOOP 4.0 motion estimate.
    static func todayStepsMetric(hasMeasuredSteps: Bool, hasImportedSteps: Bool = false) -> MetricDescriptor? {
        if hasMeasuredSteps { return metric(key: "steps", source: "my-whoop") }
        if hasImportedSteps { return metric(key: "steps", source: "apple-health") }
        return metric(key: "steps_est", source: "my-whoop")
    }

    /// Calorie twin of `todayStepsMetric`: routes to the source matching the tile's value, the imported
    /// Apple Health detail (`active_kcal`) when the day has one, else the on-device estimate
    /// (`energy_kcal` / my-whoop). Defaults to on-device when no import is present.
    static func todayCaloriesMetric(hasImportedKcal: Bool, hasOnDeviceKcal: Bool = false) -> MetricDescriptor? {
        if hasImportedKcal { return metric(key: "active_kcal", source: "apple-health") }
        if hasOnDeviceKcal { return metric(key: "energy_kcal", source: "my-whoop") }
        return metric(key: "energy_kcal", source: "my-whoop")
    }

    /// Localized display name for a catalog category, applied at the render site only. Category VALUES
    /// stay English identifiers (matching logic compares them raw), so never feed this output back into
    /// matching. Unknown values pass through.
    static func categoryDisplayName(_ category: String) -> String {
        switch category {
        case "Heart":     return String(localized: "Heart")
        case "Charge":    return String(localized: "Charge")
        case "Rest":      return String(localized: "Rest")
        case "Effort":    return String(localized: "Effort")
        case "Health":    return String(localized: "Health")
        case "Nutrition": return String(localized: "Nutrition")
        case "Mind":      return String(localized: "Mind")
        default:          return category
        }
    }

    private static func d(_ key: String, _ title: String, _ category: String, _ unit: String,
                          _ source: String, _ icon: String, _ decimals: Int,
                          _ higherIsBetter: Bool?, _ description: String? = nil) -> MetricDescriptor {
        MetricDescriptor(key: key, title: title, category: category, unit: unit,
                         source: source, icon: icon, decimals: decimals, higherIsBetter: higherIsBetter,
                         description: description)
    }
}
