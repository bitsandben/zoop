import Foundation
import StrandAnalytics
import StrandDesign

extension SleepPersonalRange {
    var confidence: MetricReadout.Confidence {
        switch status {
        case .calibrating: return .calibrating(nightsLeft: nightsLeft)
        case .provisional: return .building
        case .stale: return .stale(since: lastSample ?? Date())
        default: return .solid
        }
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
