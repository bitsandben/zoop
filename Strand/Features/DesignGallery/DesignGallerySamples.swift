import SwiftUI
import StrandDesign

// Fixtures for the Design Gallery: one readout per state the Metric* components must render (solid,
// provisional, calibrating, stale, unavailable) and every word of the closed verdict vocabulary.
// Debug-tool copy, so English only and outside the catalogue.

enum DesignGallerySamples {
    static let lastWeek = Date().addingTimeInterval(-6 * 86_400)

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
        meaning: "Your skin temperature is within the usual range.", confidence: .calibrating(nightsLeft: 3))
    static let respStale = MetricReadout(
        id: .respiratoryRate, label: "Respiratory rate", value: 15.8, unit: .breathsPerMinute,
        typicalRange: 14.2...15.4, delta: 0.9, verdict: .above,
        meaning: "You breathed a little faster than usual.", confidence: .stale(since: lastWeek))
    static let respBelow = MetricReadout(
        id: .respiratoryRate, label: "Respiratory rate", value: 13.1, unit: .breathsPerMinute,
        typicalRange: 14.2...15.4, delta: -1.7, verdict: .below,
        meaning: "You breathed slower than usual.")
    static let spo2Empty = MetricReadout(
        id: .spo2, label: "Blood oxygen", value: nil, unit: .percent,
        verdict: .unavailable(.noData(since: lastWeek)),
        meaning: "Wear the strap overnight to measure blood oxygen.")
    static let recoveryCalibrating = MetricReadout(
        id: .recovery, label: "Recovery", value: nil, unit: .percent,
        verdict: .unavailable(.calibrating(nightsLeft: 3)),
        meaning: "Your recovery needs a few more nights of baseline.", tint: .recovery)

    static func recovery(_ score: Double) -> MetricReadout {
        MetricReadout(id: .recovery, label: "Recovery", value: score, unit: .percent, typicalRange: 52...74,
                      delta: score - 63, verdict: .score(score), meaning: "Example meaning for this band.",
                      tint: .recovery)
    }

    static func load(_ band: LoadBand, strain: Double) -> MetricReadout {
        MetricReadout(id: .strain, label: "Strain", value: strain, unit: .score(fractionDigits: 1),
                      verdict: .load(band), meaning: "Example meaning for this load.", tint: .strain)
    }

    static let sleepMedium = MetricReadout(
        id: .sleepScore, label: "Sleep", value: 61, unit: .score, typicalRange: 64...82,
        delta: -9, verdict: .score(61), meaning: "You slept less than you needed.", tint: .sleep)
    static let steps = MetricReadout(
        id: .steps, label: "Steps", value: 12_345, unit: .steps, delta: 2_100,
        deltaReference: .yesterday, verdict: .typical, meaning: "You moved about as much as usual.")

    /// Every confidence / data state, in reading order.
    static let states: [(String, MetricReadout)] = [
        ("Solid", hrvSolid), ("Provisional (building)", rhrProvisional),
        ("Calibrating (population range)", tempCalibrating), ("Stale", respStale),
        ("Unavailable: no data", spo2Empty), ("Unavailable: calibrating", recoveryCalibrating),
    ]

    /// The closed verdict vocabulary (CONCEPT §1.1).
    static let verdicts: [MetricReadout] = [
        hrvSolid, rhrProvisional, respBelow,
        recovery(82), recovery(50), recovery(20),
        load(.restorative, strain: 6.1), load(.building, strain: 10.4),
        load(.demanding, strain: 14.2), load(.overreaching, strain: 18.7),
        spo2Empty, recoveryCalibrating,
    ]

    static let tiles: [MetricReadout] = [hrvSolid, rhrProvisional, tempCalibrating, respStale,
                                          spo2Empty, recovery(78), sleepMedium, steps]

    /// 30 days with a two-day gap, so the broken line is visible.
    static let trend: [MetricExplanation.TrendPoint] = (0..<30).filter { $0 != 12 && $0 != 13 }.map { day in
        let date = Calendar.current.date(byAdding: .day, value: day - 29, to: Calendar.current.startOfDay(for: Date()))!
        return MetricExplanation.TrendPoint(date: date, value: 53 + 6 * sin(Double(day) / 3))
    }

    static let explanation = MetricExplanation(
        whatItIs: "Heart rate variability is the variation between heartbeats. Higher usually means better recovered.",
        method: .init(name: "RMSSD, deep sleep",
                      summary: "Root mean square of successive beat differences during deep sleep.",
                      citation: "Plews et al., 2012"),
        dataUsed: .init(count: .nights(14),
                        window: DateInterval(start: lastWeek.addingTimeInterval(-7 * 86_400), end: lastWeek),
                        source: "WHOOP 4.0"),
        confidenceReason: "12 of 14 nights had a clean measurement window.",
        trend: trend,
        contributors: [
            .init(id: "sleep", label: "Sleep duration", detail: "Long nights raise your HRV.", effect: .raises),
            .init(id: "alcohol", label: "Alcohol", detail: "Evenings with alcohol lowered it by 9 ms.", effect: .lowers),
        ])

    static let emptyExplanation = MetricExplanation(
        whatItIs: "Blood oxygen is the share of haemoglobin carrying oxygen.",
        method: .init(name: "Red / infrared ratio", summary: "Ratio of red to infrared light absorption at night."),
        dataUsed: .init(count: .nights(0)))
}
