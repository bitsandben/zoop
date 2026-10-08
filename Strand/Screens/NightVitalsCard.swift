import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Night vitals (Zoop)
//
// The night's own body readings on the Sleep screen: heart-rate variability, resting heart rate,
// breathing rate, blood oxygen and skin temperature, each beside the wearer's average over the 30 nights
// before it. Reads only the persisted daily row of the night's wake day, the same row Recovery is
// scored from, so the two screens show the same numbers.

struct NightVitalsCard: View {
    /// The daily row of the night shown above (keyed by the wake day), nil when that day has no row.
    let day: DailyMetric?
    /// The stored daily history, oldest first; the baseline is the 30 days before `day`.
    let history: [DailyMetric]

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""

    private var fahrenheit: Bool {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                     override: temperatureRaw) == .fahrenheit
    }

    /// One vital: its value tonight, the prior-30-night mean, and which direction reads as better.
    private struct Vital: Identifiable {
        let id: String
        let label: String
        let value: Double?
        let baseline: Double?
        let format: (Double) -> String
        let deltaFormat: (Double) -> String
        /// true = higher is better, false = lower is better, nil = closer to baseline is better.
        let higherIsBetter: Bool?
    }

    private var vitals: [Vital] {
        guard let day else { return [] }
        let prior = history.filter { $0.day < day.day }.suffix(30)
        func mean(_ pick: (DailyMetric) -> Double?) -> Double? {
            let v = prior.compactMap(pick)
            return v.count >= 3 ? v.reduce(0, +) / Double(v.count) : nil
        }
        let loc = AppLanguage.activeLocale
        let tempScale = fahrenheit ? 1.8 : 1.0
        let tempUnit = fahrenheit ? "°F" : "°C"
        return [
            Vital(id: "hrv", label: String(localized: "Heart rate variability"), value: day.avgHrv,
                  baseline: mean(\.avgHrv), format: { "\(Int($0.rounded())) ms" },
                  deltaFormat: { String(format: "%+.0f ms", locale: loc, $0) }, higherIsBetter: true),
            Vital(id: "rhr", label: String(localized: "Resting heart rate"), value: day.restingHr.map(Double.init),
                  baseline: mean { $0.restingHr.map(Double.init) }, format: { "\(Int($0.rounded())) bpm" },
                  deltaFormat: { String(format: "%+.0f bpm", locale: loc, $0) }, higherIsBetter: false),
            Vital(id: "resp", label: String(localized: "Respiratory rate"), value: day.respRateBpm,
                  baseline: mean(\.respRateBpm), format: { String(format: "%.1f rpm", locale: loc, $0) },
                  deltaFormat: { String(format: "%+.1f rpm", locale: loc, $0) }, higherIsBetter: nil),
            Vital(id: "spo2", label: String(localized: "Blood oxygen"), value: day.spo2Pct,
                  baseline: mean(\.spo2Pct), format: { String(format: "%.0f%%", locale: loc, $0) },
                  deltaFormat: { String(format: "%+.1f%%", locale: loc, $0) }, higherIsBetter: true),
            // Skin temperature is already a deviation from the personal baseline, so its "baseline" is 0.
            Vital(id: "skin", label: String(localized: "Skin temperature"), value: day.skinTempDevC.map { $0 * tempScale },
                  baseline: day.skinTempDevC == nil ? nil : 0,
                  format: { String(format: "%+.1f %@", locale: loc, $0, tempUnit) },
                  deltaFormat: { String(format: "%+.1f %@", locale: loc, $0, tempUnit) }, higherIsBetter: nil),
        ].filter { $0.value != nil }
    }

    var body: some View {
        let items = vitals
        if !items.isEmpty {
            ZoopCard {
                VStack(alignment: .leading, spacing: ZoopMetrics.cardInnerSpacing) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Night vitals").strandOverline()
                        Spacer()
                        Text("vs. previous 30 nights")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: ZoopMetrics.space3),
                                        GridItem(.flexible(), spacing: ZoopMetrics.space3)],
                              alignment: .leading, spacing: ZoopMetrics.space3) {
                        ForEach(items) { tile($0) }
                    }
                }
            }
        }
    }

    private func tile(_ v: Vital) -> some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.space1) {
            Text(v.label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(verbatim: v.value.map(v.format) ?? "–")
                .font(StrandFont.number(22))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let value = v.value, let base = v.baseline, v.id != "skin" {
                // A change too small to print reads as +0, never as "-0.0".
                let raw = value - base
                let delta = abs(raw) < 0.05 ? 0 : raw
                Text(verbatim: v.deltaFormat(delta))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(tint(delta: delta, higherIsBetter: v.higherIsBetter))
            } else if v.id == "skin" {
                Text("from your baseline")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZoopMetrics.space3)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceInset))
        .accessibilityElement(children: .combine)
    }

    /// Green when the night moved the good way, amber the other way, neutral when the change is tiny or
    /// the vital has no better direction.
    private func tint(delta: Double, higherIsBetter: Bool?) -> Color {
        guard let higher = higherIsBetter, abs(delta) >= 0.5 else { return StrandPalette.textTertiary }
        return (delta > 0) == higher ? StrandPalette.statusPositive : StrandPalette.statusWarning
    }
}
