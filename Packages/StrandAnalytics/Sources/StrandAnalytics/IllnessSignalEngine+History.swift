import Foundation
import WhoopStore

// The daily-history half of the illness resolver: turns the stored nightly rows into the oriented
// z-vector `evaluate` scores. It used to live inline in the app layer, which made the app a second
// place that decided what "out of range" means; keeping it here leaves one resolver for the fact.

public extension IllnessSignalEngine {

    /// Nights of history needed before the watch looks at the newest one at all.
    static let minHistoryDays = 14

    /// Plain deltas for the caller's "why" phrases. Separate from the z-vector on purpose: the phrase
    /// reads in the user's units against a plain mean, the gate reads robust z against the EWMA baseline.
    struct Deltas: Equatable, Sendable {
        /// Newest night's resting HR above the baseline-window mean, rounded bpm; nil when not above.
        public let restingHRAboveBpm: Int?
        /// Newest night's HRV below the baseline-window mean, rounded percent; nil when not below.
        public let hrvBelowPercent: Int?
        /// Newest night's skin-temperature deviation (°C) when it is a positive deviation reading.
        public let skinTempRiseC: Double?
        /// Whether the newest night's respiration sits above the baseline-window mean.
        public let respirationUp: Bool
    }

    /// Everything `evaluate` and the Test Centre distance read need from the history.
    struct HistoryReading: Equatable, Sendable {
        public let inputs: Inputs
        /// True when the resting-HR or HRV baseline is trusted (≥ 14 valid nights, not stale).
        public let baselineTrusted: Bool
        public let deltas: Deltas

        /// The same oriented z-vector for `IllnessDistance` (Test Centre only); absent signals drop out.
        public var distanceFeatures: IllnessDistance.FeatureVector {
            func z(_ r: SignalReading?) -> Double? {
                guard let r, r.present else { return nil }
                return r.zIllnessward
            }
            return IllnessDistance.FeatureVector(restingHR: z(inputs.restingHR), rmssd: z(inputs.hrv),
                                                 skinTemp: z(inputs.skinTemp), respiration: z(inputs.respiration))
        }
    }

    /// Reads the newest night of `days` (oldest first) against the personal baseline.
    ///
    /// The recent window is the last two nights; the baseline is the ~28 nights ending three nights ago,
    /// so a building illness cannot drag its own baseline along. Nil below `minHistoryDays`.
    static func reading(days: [DailyMetric]) -> HistoryReading? {
        guard days.count >= minHistoryDays, let latest = days.last else { return nil }
        let recent = Array(days.suffix(2))
        let base = Array(days.suffix(31).dropLast(3))
        func mean(_ vals: [Double]) -> Double? { vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count) }

        func signal(_ kp: (DailyMetric) -> Double?, cfgKey: String,
                    illnessUp: Bool) -> (reading: SignalReading, trusted: Bool)? {
            guard let cfg = Baselines.metricCfg[cfgKey], let recentMean = mean(recent.compactMap(kp)),
                  let latestValue = kp(latest) else { return nil }
            let state = Baselines.foldHistory(base.map(kp), cfg: cfg)
            guard state.usable else { return (SignalReading(zIllnessward: 0, present: false), false) }
            let dev = Baselines.deviation(recentMean, state: state)
            let latestDev = Baselines.deviation(latestValue, state: state)
            // Two-night smoothing, but a signal only counts while the newest night independently clears
            // the same illness-ward threshold (#2533).
            let z = illnessUp ? min(dev.z, latestDev.z) : min(-dev.z, -latestDev.z)
            return (SignalReading(zIllnessward: z), state.trusted)
        }

        let rhr = signal({ $0.restingHr.map(Double.init) }, cfgKey: "resting_hr", illnessUp: true)
        let hrv = signal({ $0.avgHrv }, cfgKey: "hrv", illnessUp: false)
        let resp = signal({ $0.respRateBpm }, cfgKey: "resp", illnessUp: true)
        // Skin temp is stored as a °C deviation, so it is z-scored against a zero-centred personal spread
        // inside VitalBands. Imported nights carry an absolute °C in the same column and are skipped there.
        let skin = VitalBands.skinTempIllnessZ(recent: recent.map(\.skinTempDevC), latest: latest.skinTempDevC)
            .map { SignalReading(zIllnessward: $0) }

        var rhrAbove: Int?
        if let r = latest.restingHr.map(Double.init),
           let b = mean(base.compactMap { $0.restingHr.map(Double.init) }), r > b {
            rhrAbove = Int((r - b).rounded())
        }
        var hrvBelow: Int?
        if let r = latest.avgHrv, let b = mean(base.compactMap(\.avgHrv)), b > 0, r < b {
            hrvBelow = Int(((1 - r / b) * 100).rounded())
        }
        var skinRise: Double?
        if let r = latest.skinTempDevC, r > 0, !VitalBands.isAbsoluteSkinTemp(r) { skinRise = r }
        var respUp = false
        if let r = latest.respRateBpm, let b = mean(base.compactMap(\.respRateBpm)), r > b { respUp = true }

        return HistoryReading(
            inputs: Inputs(restingHR: rhr?.reading, skinTemp: skin, hrv: hrv?.reading, respiration: resp?.reading),
            baselineTrusted: (rhr?.trusted ?? false) || (hrv?.trusted ?? false),
            deltas: Deltas(restingHRAboveBpm: rhrAbove, hrvBelowPercent: hrvBelow,
                           skinTempRiseC: skinRise, respirationUp: respUp))
    }
}

public extension IllnessSignalEngine.Result {

    /// The heads-up as an `Assessment`: the composite score, `.calibrating` while the baseline is not yet
    /// trusted (the engine then never raises), and the level as the reason.
    var assessment: Assessment<Double, IllnessSignalEngine.Level> {
        Assessment(value: score,
                   confidence: message == .learningBaseline ? .calibrating : .solid,
                   reason: level)
    }
}
