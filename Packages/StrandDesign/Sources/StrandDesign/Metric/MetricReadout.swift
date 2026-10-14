import Foundation

// MARK: - Metric anatomy (CONCEPT §1.1)
//
// Every user-visible number travels as a `MetricReadout`: value, unit, the user's own typical range,
// delta, a verdict from a closed vocabulary, a one-sentence meaning and a confidence. View models
// build readouts; the Metric* views only render them, so no screen formats a number or picks a
// verdict word by itself.

/// Stable key of a metric. Doubles as the explainer route, so it must not change between releases.
public struct MetricID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let recovery: MetricID = "recovery"
    public static let strain: MetricID = "strain"
    public static let sleepScore: MetricID = "sleep_score"
    public static let hrv: MetricID = "hrv"
    public static let restingHeartRate: MetricID = "resting_hr"
    public static let respiratoryRate: MetricID = "respiratory_rate"
    public static let skinTemperature: MetricID = "skin_temperature"
    public static let spo2: MetricID = "spo2"
    public static let stress: MetricID = "stress"
    public static let fitnessAge: MetricID = "fitness_age"
    public static let vo2max: MetricID = "vo2max"
    public static let steps: MetricID = "steps"
    public static let weight: MetricID = "weight"
    public static let sleepDuration: MetricID = "sleep_duration"
}

public struct MetricReadout: Equatable, Sendable, Identifiable {

    public typealias Verdict = MetricVerdict

    /// How sure the engine is about this readout. Engines decide it; views only render it (§5.2).
    public enum Confidence: Equatable, Sendable {
        /// Not enough own nights for a personal range yet; the range shown is the population one.
        case calibrating(nightsLeft: Int)
        /// A value exists but its baseline is still settling ("provisional"): dashed band.
        case building
        case solid
        /// The newest data is old; the value is greyed and dated.
        case stale(since: Date)
    }

    /// What the delta is measured against. Cumulative counts (steps) compare to yesterday.
    public enum DeltaReference: Equatable, Sendable { case typical, yesterday }

    /// Fixed metric colours (§7.5). Recovery follows its score band instead of a fixed hue.
    public enum Tint: Equatable, Sendable { case neutral, recovery, strain, sleep, stress, fasting }

    public let id: MetricID
    public let label: LocalizedStringResource
    /// nil only together with `.unavailable`.
    public let value: Double?
    public let unit: MetricUnit
    public let typicalRange: ClosedRange<Double>?
    /// false while the range is the population fallback (drawn dashed, labelled as such).
    public let rangeIsPersonal: Bool
    public let delta: Double?
    public let deltaReference: DeltaReference
    public let verdict: MetricVerdict
    /// One sentence, second person, ≤ 90 characters, from a (metric, verdict) template.
    public let meaning: LocalizedStringResource
    public let confidence: Confidence
    public let tint: Tint

    public init(
        id: MetricID,
        label: LocalizedStringResource,
        value: Double?,
        unit: MetricUnit,
        typicalRange: ClosedRange<Double>? = nil,
        rangeIsPersonal: Bool = true,
        delta: Double? = nil,
        deltaReference: DeltaReference = .typical,
        verdict: MetricVerdict,
        meaning: LocalizedStringResource,
        confidence: Confidence = .solid,
        tint: Tint = .neutral
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.unit = unit
        self.typicalRange = typicalRange
        self.rangeIsPersonal = rangeIsPersonal
        self.delta = delta
        self.deltaReference = deltaReference
        self.verdict = verdict
        self.meaning = meaning
        self.confidence = confidence
        self.tint = tint
    }

    /// The value that should be drawn: none when the verdict says the metric is unavailable, even if
    /// an engine left a number behind, so the number and the "no data" wording can never disagree.
    public var displayValue: Double? {
        if case .unavailable = verdict { return nil }
        return value
    }

    /// Whether the band is drawn dashed: a population range, or a personal one still settling.
    public var rangeIsTentative: Bool {
        if !rangeIsPersonal { return true }
        if case .building = confidence { return true }
        return false
    }

    public var isStale: Bool {
        if case .stale = confidence { return true }
        return false
    }

    /// Direction of the delta, flat unless it clears the smallest worthwhile change.
    public var deltaDirection: DeltaDirection {
        guard let delta else { return .flat }
        return DeltaDirection(delta: delta, typicalRange: typicalRange)
    }
}

public enum DeltaDirection: Equatable, Sendable {
    case up, down, flat

    /// The typical range is mean ± 1 SD, so its width is 2 SD and the smallest worthwhile change
    /// (0.5 SD, Plews 2012) is a quarter of it. Without a range there is no yardstick: flat.
    public init(delta: Double, typicalRange: ClosedRange<Double>?) {
        guard let range = typicalRange, range.upperBound > range.lowerBound else {
            self = .flat
            return
        }
        let swc = (range.upperBound - range.lowerBound) / 4
        if delta >= swc { self = .up } else if delta <= -swc { self = .down } else { self = .flat }
    }
}
