import Foundation
import WhoopStore

// Daily-history half of the illness resolver: turns stored nightly rows into the oriented z-vector `evaluate`
// scores, keeping one resolver for what "out of range" means.

public extension IllnessSignalEngine {

    /// Nights of history needed before the newest one is examined.
    static let minHistoryDays = 14

    /// Plain deltas for the caller's "why" phrases (user units against a plain mean; the gate reads robust z).
    struct Deltas: Equatable, Sendable {
        /// Resting HR above the baseline-window mean, rounded bpm; nil when not above.
        public let restingHRAboveBpm: Int?
        /// HRV below the baseline-window mean, rounded percent; nil when not below.
        public let hrvBelowPercent: Int?
        /// Skin-temperature deviation (deg C) when it is a positive deviation reading.
        public let skinTempRiseC: Double?
        /// Whether respiration sits above the baseline-window mean.
        public let respirationUp: Bool
    }

    /// Everything `evaluate` and the Test Centre distance read need from the history.
    struct HistoryReading: Equatable, Sendable {
        public let inputs: Inputs
        /// True when the resting-HR or HRV baseline is trusted (>= 14 valid nights, not stale).
        public let baselineTrusted: Bool
        public let deltas: Deltas

        /// The same oriented z-vector for `IllnessDistance` (Test Centre only).
        public var distanceFeatures: IllnessDistance.FeatureVector {
            func z(_ r: SignalReading?) -> Double? {
                guard let r, r.present else { return nil }
                return r.zIllnessward
            }
            return IllnessDistance.FeatureVector(restingHR: z(inputs.restingHR), rmssd: z(inputs.hrv),
                                                 skinTemp: z(inputs.skinTemp), respiration: z(inputs.respiration))
        }
    }

    /// Reads the newest night of `days` (oldest first) against the personal baseline: recent window = last two
    /// nights, baseline = ~28 nights ending three nights ago so a building illness can't drag it. Nil below `minHistoryDays`.
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
            // Two-night smoothing; a signal counts only while the newest night alone clears the illness-ward threshold (#2533).
            let z = illnessUp ? min(dev.z, latestDev.z) : min(-dev.z, -latestDev.z)
            return (SignalReading(zIllnessward: z), state.trusted)
        }

        let rhr = signal({ $0.restingHr.map(Double.init) }, cfgKey: "resting_hr", illnessUp: true)
        let hrv = signal({ $0.avgHrv }, cfgKey: "hrv", illnessUp: false)
        let resp = signal({ $0.respRateBpm }, cfgKey: "resp", illnessUp: true)
        // Skin temp is a deg C deviation, z-scored against a zero-centred spread in VitalBands; imported absolute values are skipped there.
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

    /// The heads-up as an `Assessment`: composite score, `.calibrating` until the baseline is trusted, level as reason.
    var assessment: Assessment<Double, IllnessSignalEngine.Level> {
        Assessment(value: score,
                   confidence: message == .learningBaseline ? .calibrating : .solid,
                   reason: level)
    }
}
