import Foundation

// MARK: - Personal range (CONCEPT §1.1, §5.3)
//
// The typical range behind every Sleep readout: the `Baselines` EWMA (14-night centre half-life) ± one
// SD-equivalent, with the same calibrating / provisional / trusted / stale states every engine uses.
// The app layer maps `status` to a `MetricReadout.Confidence` and builds readouts.

public struct SleepPersonalRange: Equatable, Sendable {
    public let range: ClosedRange<Double>
    /// false while the population range stands in (fewer than `Baselines.minNightsSeed` nights).
    public let isPersonal: Bool
    /// The personal centre; nil while calibrating, so no delta is drawn against a population guess.
    public let baseline: Double?
    public let status: BaselineStatus
    /// Nights still needed before the range turns personal; 0 once it has.
    public let nightsLeft: Int
    public let lastSample: Date?
    public let nights: Int

    /// Folds `history` (oldest first, nil = missing night, tonight excluded) into a range.
    public static func resolve(history: [Double?], cfg: MetricCfg, population: ClosedRange<Double>,
                               lastSample: Date?) -> SleepPersonalRange {
        let state = Baselines.foldHistory(history, cfg: cfg)
        guard state.status != .calibrating else {
            let left = max(1, Baselines.minNightsSeed - state.nValid)
            return SleepPersonalRange(range: population, isPersonal: false, baseline: nil, status: state.status,
                                      nightsLeft: left, lastSample: lastSample, nights: state.nValid)
        }
        let sigma = Baselines.sigma(state)
        let lower = max(cfg.minVal, state.baseline - sigma)
        let upper = min(cfg.maxVal, state.baseline + sigma)
        return SleepPersonalRange(range: lower...max(lower, upper), isPersonal: true, baseline: state.baseline,
                                  status: state.status, nightsLeft: 0, lastSample: lastSample, nights: state.nValid)
    }
}

/// Bounds and floors per Sleep quantity. Half-lives follow the shared vitals config (14 / 21 nights).
public enum SleepRangeConfig {
    private static func cfg(_ lo: Double, _ hi: Double, floor: Double) -> MetricCfg {
        MetricCfg(minVal: lo, maxVal: hi, floorSpread: floor, halfLifeB: 14, halfLifeS: 21)
    }

    // Durations are in seconds, matching `MetricUnit.duration`.
    public static let duration = cfg(3_600, 50_400, floor: 900)
    public static let stage = cfg(0, 36_000, floor: 300)
    public static let efficiency = cfg(40, 100, floor: 1.5)
    public static let score = cfg(0, 100, floor: 3)
    public static let debt = cfg(0, 36_000, floor: 600)
    public static let regularity = cfg(-100, 100, floor: 3)
    public static let spo2 = cfg(80, 100, floor: 0.5)
    public static let skinDeviation = cfg(-5, 5, floor: 0.1)
    public static var hrv: MetricCfg { Baselines.metricCfg["hrv"] ?? cfg(5, 250, floor: 5) }
    public static var restingHR: MetricCfg { Baselines.metricCfg["resting_hr"] ?? cfg(30, 120, floor: 2) }
    public static var respiratory: MetricCfg { Baselines.metricCfg["resp"] ?? cfg(4, 40, floor: 0.5) }

    // Population ranges stand in while calibrating and are labelled as such (healthy adults:
    // AASM/NSF 7–9 h; stage shares of a 7.5 h night after Ohayon et al., 2004).
    public static let durationPopulation = 25_200.0...32_400.0
    public static let efficiencyPopulation = 85.0...95.0
    public static let deepPopulation = 3_480.0...6_240.0
    public static let remPopulation = 5_400.0...6_780.0
    public static let lightPopulation = 13_500.0...16_200.0
    public static let awakePopulation = 1_200.0...3_600.0
    public static let scorePopulation = 67.0...100.0
    public static let debtPopulation = 0.0...3_600.0
    public static let regularityPopulation = 70.0...90.0
    public static let hrvPopulation = 30.0...80.0
    public static let restingHRPopulation = 50.0...70.0
    public static let respiratoryPopulation = 12.0...20.0
    public static let spo2Population = 95.0...100.0
    public static let skinPopulation = -0.5...0.5
}
