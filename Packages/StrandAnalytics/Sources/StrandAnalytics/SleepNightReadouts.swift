import Foundation

// MARK: - Sleep night readouts (Zoop)
//
// Pure helpers behind three Sleep-screen readouts: how long it took to fall asleep, the typical share
// of the night each stage takes, and which overnight signal curves are plausible enough to draw. They
// read only numbers the app already stores; none of them changes a score.
//
// These are presentation bands, not clinical thresholds. Every edge is pinned by `SleepNightReadoutsTests`.

// MARK: Sleep latency

public enum SleepLatency {

    /// The three steps on the latency track.
    public enum Band: String, Sendable {
        case fast, normal, late
    }

    /// Under this many minutes reads as fast.
    public static let fastBelowMin: Double = 10
    /// Over this many minutes reads as late. Between the two edges (inclusive) reads as normal.
    public static let lateAboveMin: Double = 30
    /// The latency the right end of the track stands for; longer values pin to the end.
    public static let trackMaxMin: Double = 45

    /// Minutes from the start of the night (time 0, the in-bed start) to the first sleep segment.
    ///
    /// `segments` are `(start, end, asleep)` in seconds from the in-bed start, in any order. Returns nil
    /// when nothing in the night was asleep, so a night without a staged timeline shows no latency at all.
    public static func minutes(segments: [(start: Double, end: Double, asleep: Bool)]) -> Double? {
        guard let first = segments.filter({ $0.asleep && $0.end > $0.start })
            .min(by: { $0.start < $1.start }) else { return nil }
        return max(0, first.start) / 60
    }

    public static func band(minutes: Double) -> Band {
        if minutes < fastBelowMin { return .fast }
        if minutes > lateAboveMin { return .late }
        return .normal
    }

    /// Where the dot sits on the track, 0...1.
    public static func trackFraction(minutes: Double) -> Double {
        min(1, max(0, minutes / trackMaxMin))
    }
}

// MARK: Typical stage share

public enum StageShareBands {

    /// One night's stored stage minutes. `efficiency` is asleep / in-bed, as 0...1 or as a percentage.
    public struct Night: Equatable, Sendable {
        public var lightMin: Double?
        public var deepMin: Double?
        public var remMin: Double?
        public var efficiency: Double?
        public init(lightMin: Double?, deepMin: Double?, remMin: Double?, efficiency: Double?) {
            self.lightMin = lightMin
            self.deepMin = deepMin
            self.remMin = remMin
            self.efficiency = efficiency
        }
    }

    /// The 25th to 75th percentile of each stage's share of time in bed, 0...1. A nil stage had fewer
    /// than `minNights` usable nights.
    public struct Bands: Equatable, Sendable {
        public var awake: ClosedRange<Double>?
        public var light: ClosedRange<Double>?
        public var deep: ClosedRange<Double>?
        public var rem: ClosedRange<Double>?
    }

    public static let minNights = 5

    /// Shares over time in bed, the same denominator the stage cells print. Awake is `1 - efficiency`;
    /// each sleep stage is its share of asleep time scaled by efficiency.
    public static func bands(_ nights: [Night]) -> Bands {
        var awake: [Double] = [], light: [Double] = [], deep: [Double] = [], rem: [Double] = []
        for n in nights {
            guard let l = n.lightMin, let d = n.deepMin, let r = n.remMin, var e = n.efficiency else { continue }
            if e > 1.5 { e /= 100 }
            let asleep = l + d + r
            guard asleep > 0, e > 0.3, e <= 1 else { continue }
            awake.append(1 - e)
            light.append(l / asleep * e)
            deep.append(d / asleep * e)
            rem.append(r / asleep * e)
        }
        return Bands(awake: iqr(awake), light: iqr(light), deep: iqr(deep), rem: iqr(rem))
    }

    /// 25th...75th percentile with linear interpolation, nil under `minNights` values.
    static func iqr(_ raw: [Double]) -> ClosedRange<Double>? {
        let v = raw.sorted()
        guard v.count >= minNights else { return nil }
        func pct(_ p: Double) -> Double {
            let idx = p * Double(v.count - 1)
            let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
            let f = idx - Double(lo)
            return v[lo] * (1 - f) + v[hi] * f
        }
        return pct(0.25)...pct(0.75)
    }
}

// MARK: Overnight signal curves

public enum NightSignal {

    /// The four curves the night chart can switch between.
    public enum Metric: String, CaseIterable, Sendable {
        case heartRate, hrv, respiratoryRate, spo2

        /// The range a single plotted value must fall in to be drawn. A stream outside it is a raw
        /// sensor quantity (a WHOOP respiration waveform, a red/IR ratio), not this metric.
        public var plausible: ClosedRange<Double> {
            switch self {
            case .heartRate:       return 25...220
            case .hrv:             return 1...300
            case .respiratoryRate: return 4...40
            case .spo2:            return 70...100
            }
        }
    }

    /// Fewest plausible points worth a curve.
    public static let minPoints = 8
    /// Share of a stream's values that must be plausible before it is drawn at all.
    public static let minPlausibleShare = 0.8

    /// The values to plot, or nil when the stream is too short or mostly not this metric.
    /// Implausible values are dropped, never clamped.
    public static func plottable(_ values: [Double], metric: Metric) -> [Int]? {
        guard !values.isEmpty else { return nil }
        let keep = values.indices.filter { metric.plausible.contains(values[$0]) }
        guard keep.count >= minPoints,
              Double(keep.count) / Double(values.count) >= minPlausibleShare else { return nil }
        return keep
    }

    /// Centered moving average over `window` points (odd; shrinks at the edges).
    public static func smoothed(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > 2 else { return values }
        let half = window / 2
        return values.indices.map { i in
            let lo = max(0, i - half), hi = min(values.count - 1, i + half)
            let slice = values[lo...hi]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    public static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
