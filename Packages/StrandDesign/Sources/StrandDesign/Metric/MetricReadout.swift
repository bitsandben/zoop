import Foundation

// MARK: - Metric anatomy
//
// Every user-visible number travels as a `MetricReadout`: value, unit, typical range, delta, a verdict
// from a closed vocabulary, a one-sentence meaning and a confidence. View models build readouts; views
// only render them.

/// Stable key of a metric; doubles as the explainer route, so it must not change between releases.
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

    /// Which direction is good for the package's own metrics; app-defined ids pass theirs to the readout.
    public var defaultPolarity: MetricPolarity {
        switch self {
        case .hrv, .spo2, .vo2max, .steps, .sleepDuration, .recovery, .sleepScore: return .higherIsBetter
        case .restingHeartRate, .stress, .fitnessAge: return .lowerIsBetter
        default: return .neutral
        }
    }
}

/// Which side of the typical range is good. Decides whether "above" / "below" read as better or worse.
public enum MetricPolarity: Equatable, Sendable {
    case higherIsBetter, lowerIsBetter
    /// Either side is just different (skin temperature, respiratory rate, weight).
    case neutral
}

/// How a verdict reads once polarity is applied: the tint and the wording follow it.
public enum MetricAssessment: Equatable, Sendable {
    case better, worse, neutral

    public init(verdict: MetricVerdict, polarity: MetricPolarity) {
        switch (verdict, polarity) {
        case (.above, .higherIsBetter), (.below, .lowerIsBetter): self = .better
        case (.above, .lowerIsBetter), (.below, .higherIsBetter): self = .worse
        default: self = .neutral
        }
    }
}

public struct MetricReadout: Equatable, Sendable, Identifiable {

    public typealias Verdict = MetricVerdict

    /// How sure the engine is about this readout. Engines decide it; views only render it.
    public enum Confidence: Equatable, Sendable {
        /// Not enough own nights for a personal range; the range shown is the population one.
        case calibrating(nightsLeft: Int)
        /// Value exists but its baseline is still settling: dashed band.
        case building
        case solid
        /// The newest data is old; the value is greyed and dated.
        case stale(since: Date)
    }

    /// What the delta is measured against. Cumulative counts (steps) compare to yesterday.
    public enum DeltaReference: Equatable, Sendable { case typical, yesterday }

    /// Fixed metric colours; recovery follows its score band instead.
    public enum Tint: Equatable, Sendable { case neutral, recovery, strain, sleep, stress, fasting }

    public let id: MetricID
    public let label: LocalizedStringResource
    public let value: Double?
    public let unit: MetricUnit
    public let typicalRange: ClosedRange<Double>?
    /// false while the range is the population fallback (drawn dashed).
    public let rangeIsPersonal: Bool
    public let delta: Double?
    public let deltaReference: DeltaReference
    public let verdict: MetricVerdict
    public let meaning: LocalizedStringResource
    public let confidence: Confidence
    public let tint: Tint
    public let polarity: MetricPolarity

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
        tint: Tint = .neutral,
        polarity: MetricPolarity? = nil
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
        self.polarity = polarity ?? id.defaultPolarity
    }

    /// Better / worse than the range once polarity is applied; neutral for everything else.
    public var assessment: MetricAssessment { MetricAssessment(verdict: verdict, polarity: polarity) }

    /// The value to draw: none when the verdict says unavailable, so number and "no data" wording cannot disagree.
    public var displayValue: Double? {
        if case .unavailable = verdict { return nil }
        return value
    }

    public var rangeIsTentative: Bool {
        if !rangeIsPersonal { return true }
        if case .building = confidence { return true }
        return false
    }

    public var isStale: Bool {
        if case .stale = confidence { return true }
        return false
    }

    public var deltaDirection: DeltaDirection {
        guard let delta else { return .flat }
        return DeltaDirection(delta: delta, typicalRange: typicalRange)
    }
}

public enum DeltaDirection: Equatable, Sendable {
    case up, down, flat

    /// The typical range is mean ± 1 SD, so the smallest worthwhile change (0.5 SD, Plews 2012) is a quarter of its width. No range: flat.
    public init(delta: Double, typicalRange: ClosedRange<Double>?) {
        guard let range = typicalRange, range.upperBound > range.lowerBound else {
            self = .flat
            return
        }
        let swc = (range.upperBound - range.lowerBound) / 4
        if delta >= swc { self = .up } else if delta <= -swc { self = .down } else { self = .flat }
    }
}
