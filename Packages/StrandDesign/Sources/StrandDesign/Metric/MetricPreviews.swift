#if DEBUG
import SwiftUI

// MARK: - Preview fixtures
//
// One readout per state the components must handle (§8.2): solid, provisional, calibrating, stale,
// empty, plus the score and load vocabularies.

enum MetricSamples {
    static let lastWeek = Date(timeIntervalSinceReferenceDate: 813_000_000)

    static let hrvSolid = MetricReadout(
        id: .hrv, label: "HRV", value: 62, unit: .milliseconds, typicalRange: 48...58, delta: 8,
        verdict: .above, meaning: "Your nervous system recovered well overnight.")
    static let rhrProvisional = MetricReadout(
        id: .restingHeartRate, label: "Resting heart rate", value: 54, unit: .beatsPerMinute,
        typicalRange: 51...57, delta: -1, verdict: .typical,
        meaning: "Your heart rate settled as low as usual.", confidence: .building)
    static let tempCalibrating = MetricReadout(
        id: .skinTemperature, label: "Skin temperature", value: 34.6, unit: .celsius,
        typicalRange: 33.5...35.5, rangeIsPersonal: false, verdict: .typical,
        meaning: "Your skin temperature is within the usual range.",
        confidence: .calibrating(nightsLeft: 3))
    static let respStale = MetricReadout(
        id: .respiratoryRate, label: "Respiratory rate", value: 15.8, unit: .breathsPerMinute,
        typicalRange: 14.2...15.4, delta: 0.9, verdict: .above,
        meaning: "You breathed a little faster than usual.", confidence: .stale(since: lastWeek))
    static let spo2Empty = MetricReadout(
        id: .spo2, label: "Blood oxygen", value: nil, unit: .percent,
        verdict: .unavailable(.noData(since: lastWeek)),
        meaning: "Wear the strap overnight to measure blood oxygen.")
    static let recoveryCalibrating = MetricReadout(
        id: .recovery, label: "Recovery", value: nil, unit: .percent,
        verdict: .unavailable(.calibrating(nightsLeft: 3)),
        meaning: "Your recovery needs a few more nights of baseline.", tint: .recovery)
    static let recoveryHigh = MetricReadout(
        id: .recovery, label: "Recovery", value: 78, unit: .percent, typicalRange: 52...74,
        delta: 12, verdict: .score(78), meaning: "You are ready for a demanding day.", tint: .recovery)
    static let sleepMedium = MetricReadout(
        id: .sleepScore, label: "Sleep", value: 61, unit: .score, typicalRange: 64...82,
        delta: -9, verdict: .score(61), meaning: "You slept less than you needed.", tint: .sleep)
    static let strainLoad = MetricReadout(
        id: .strain, label: "Strain", value: 14.2, unit: .score(fractionDigits: 1),
        verdict: .load(.demanding), meaning: "Today asked more of you than most days.", tint: .strain)
    static let steps = MetricReadout(
        id: .steps, label: "Steps", value: 12_345, unit: .steps, delta: 2_100,
        deltaReference: .yesterday, verdict: .typical, meaning: "You moved about as much as usual.")

    static let all = [hrvSolid, rhrProvisional, tempCalibrating, respStale, spo2Empty,
                      recoveryCalibrating, recoveryHigh, sleepMedium, strainLoad, steps]

    /// 30 days with a two-day gap, so the broken line shows.
    static let trend: [MetricExplanation.TrendPoint] = (0..<30).filter { $0 != 12 && $0 != 13 }.map { day in
        let date = lastWeek.addingTimeInterval(Double(day - 30) * 86_400)
        let value: Double = 53 + 6 * sin(Double(day) / 3)
        return MetricExplanation.TrendPoint(date: date, value: value)
    }

    static let explanation = MetricExplanation(
        whatItIs: "Heart rate variability is the variation between heartbeats. Higher usually means better recovered.",
        method: .init(name: "RMSSD, deep sleep", summary: "Root mean square of successive beat differences during deep sleep.",
                      citation: "Plews et al., 2012"),
        dataUsed: .init(count: .nights(14), window: DateInterval(start: lastWeek.addingTimeInterval(-7 * 86_400), end: lastWeek),
                        source: "WHOOP 4.0"),
        confidenceReason: "12 of 14 nights had a clean measurement window.",
        trend: trend,
        contributors: [
            .init(id: "sleep", label: "Sleep duration", detail: "Long nights raise your HRV.", effect: .raises),
            .init(id: "alcohol", label: "Alcohol", detail: "Evenings with alcohol lowered it by 9 ms.", effect: .lowers),
        ])
}

private struct MetricGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MetricHero(MetricSamples.hrvSolid)
                MetricHero(MetricSamples.recoveryCalibrating)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    ForEach(MetricSamples.all.indices, id: \.self) { MetricTile(MetricSamples.all[$0]) }
                }
                VStack(spacing: 0) {
                    ForEach(MetricSamples.all.indices, id: \.self) { MetricRow(MetricSamples.all[$0]); Divider() }
                }
            }
            .padding(16)
        }
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("Metric · all states · EN dark") {
    MetricGallery().preferredColorScheme(.dark)
}

#Preview("Metric · DE · pastel light") {
    MetricGallery()
        .zoopTheme(ZoopTheme.pastel.rawValue)
        .environment(\.locale, Locale(identifier: "de_DE"))
        .preferredColorScheme(.light)
}

#Preview("Metric · Dynamic Type XXL") {
    MetricGallery()
        .environment(\.dynamicTypeSize, .accessibility3)
        .preferredColorScheme(.dark)
}

#Preview("Metric explainer") {
    MetricExplainerSheet(MetricSamples.hrvSolid, explanation: MetricSamples.explanation)
        .preferredColorScheme(.dark)
}
#endif
