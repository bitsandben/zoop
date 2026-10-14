import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Personal range (CONCEPT §1.1, §5.3)
//
// The typical range behind every Sleep readout: the `Baselines` EWMA (14-night centre half-life) ± one
// SD-equivalent, with the same calibrating / provisional / trusted / stale states every engine uses.
// Pure, and a candidate to move into StrandAnalytics next to `Baselines` once WP-04 lands.

struct SleepPersonalRange: Equatable {
    let range: ClosedRange<Double>
    /// false while the population range stands in (fewer than `Baselines.minNightsSeed` nights).
    let isPersonal: Bool
    /// The personal centre; nil while calibrating, so no delta is drawn against a population guess.
    let baseline: Double?
    let confidence: MetricReadout.Confidence
    let nights: Int

    /// Folds `history` (oldest first, nil = missing night, tonight excluded) into a range.
    static func resolve(history: [Double?], cfg: MetricCfg, population: ClosedRange<Double>,
                        lastSample: Date?) -> SleepPersonalRange {
        let state = Baselines.foldHistory(history, cfg: cfg)
        guard state.status != .calibrating else {
            let left = max(1, Baselines.minNightsSeed - state.nValid)
            return SleepPersonalRange(range: population, isPersonal: false, baseline: nil,
                                      confidence: .calibrating(nightsLeft: left), nights: state.nValid)
        }
        let sigma = Baselines.sigma(state)
        let lower = max(cfg.minVal, state.baseline - sigma)
        let upper = min(cfg.maxVal, state.baseline + sigma)
        let confidence: MetricReadout.Confidence
        switch state.status {
        case .provisional: confidence = .building
        case .stale: confidence = .stale(since: lastSample ?? Date())
        default: confidence = .solid
        }
        return SleepPersonalRange(range: lower...max(lower, upper), isPersonal: true, baseline: state.baseline,
                                  confidence: confidence, nights: state.nValid)
    }

    /// The readout for `value` against this range. A missing value turns into an explicit reason.
    func readout(id: MetricID, label: LocalizedStringResource, value: Double?, unit: MetricUnit,
                 tint: MetricReadout.Tint = .sleep,
                 meaning: (MetricVerdict) -> LocalizedStringResource) -> MetricReadout {
        guard let value else {
            let verdict = MetricVerdict.unavailable(.noData(since: nil))
            return MetricReadout(id: id, label: label, value: nil, unit: unit, verdict: verdict,
                                 meaning: SleepStrings.noValueTonight, confidence: confidence, tint: tint)
        }
        let verdict = MetricVerdict.vital(value, typicalRange: range)
        return MetricReadout(id: id, label: label, value: value, unit: unit, typicalRange: range,
                             rangeIsPersonal: isPersonal, delta: baseline.map { value - $0 },
                             verdict: verdict, meaning: meaning(verdict), confidence: confidence, tint: tint)
    }
}

/// Bounds and floors per Sleep quantity. Half-lives follow the shared vitals config (14 / 21 nights).
enum SleepRangeConfig {
    private static func cfg(_ lo: Double, _ hi: Double, floor: Double) -> MetricCfg {
        MetricCfg(minVal: lo, maxVal: hi, floorSpread: floor, halfLifeB: 14, halfLifeS: 21)
    }

    // Durations are in seconds, matching `MetricUnit.duration`.
    static let duration = cfg(3_600, 50_400, floor: 900)
    static let stage = cfg(0, 36_000, floor: 300)
    static let efficiency = cfg(40, 100, floor: 1.5)
    static let score = cfg(0, 100, floor: 3)
    static let debt = cfg(0, 36_000, floor: 600)
    static let regularity = cfg(-100, 100, floor: 3)
    static let spo2 = cfg(80, 100, floor: 0.5)
    static let skinDeviation = cfg(-5, 5, floor: 0.1)
    static var hrv: MetricCfg { Baselines.metricCfg["hrv"] ?? cfg(5, 250, floor: 5) }
    static var restingHR: MetricCfg { Baselines.metricCfg["resting_hr"] ?? cfg(30, 120, floor: 2) }
    static var respiratory: MetricCfg { Baselines.metricCfg["resp"] ?? cfg(4, 40, floor: 0.5) }

    // Population ranges stand in while calibrating and are labelled as such (healthy adults:
    // AASM/NSF 7–9 h; stage shares of a 7.5 h night after Ohayon et al., 2004).
    static let durationPopulation = 25_200.0...32_400.0
    static let efficiencyPopulation = 85.0...95.0
    static let deepPopulation = 3_480.0...6_240.0
    static let remPopulation = 5_400.0...6_780.0
    static let lightPopulation = 13_500.0...16_200.0
    static let awakePopulation = 1_200.0...3_600.0
    static let scorePopulation = 67.0...100.0
    static let debtPopulation = 0.0...3_600.0
    static let regularityPopulation = 70.0...90.0
    static let hrvPopulation = 30.0...80.0
    static let restingHRPopulation = 50.0...70.0
    static let respiratoryPopulation = 12.0...20.0
    static let spo2Population = 95.0...100.0
    static let skinPopulation = -0.5...0.5
}
